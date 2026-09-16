# Set 1 Capstone
### Derived Architecture | Single Entry Point | Immutable Audit Trail
---

A public parks site and a private reservation system behind one entry point. Static content served from a locked S3 origin, the reservation application from an internal load balancer with no public address reached through a VPC origin. WAF at the edge. Access logs under Object Lock so the audit trail survives a compromise of the servers it records.

The capstone runs against a prompt revealed only once the Set's projects are complete. It describes an outcome and its constraints rather than naming services, so the work is deriving the architecture from the outcome. The design phase is capped at 20 minutes. The build is untimed and runs from the design alone, with the Set's `setup.md` files open only to locate settings, never to determine what to build.

**Design phase** · 18 minutes, capped at 20 \
**Region** · us-west-2 \
**References** · setup.md from the four Set 1 projects, available during the build only

## The Prompt

A county parks department is putting its system online.

Trail maps, park hours, and facility rules need to be readable by anyone on the internet, quickly, from anywhere in the county.

Residents reserve picnic shelters and pay fees. That reservation system runs on servers holding payment and personal information. Those servers must not be reachable from the internet, and must not be able to reach out to it. They still need to do their jobs, which includes writing to storage and being administered without anyone opening a port.

The department has been getting scripted traffic that hammers the reservation pages in bursts and degrades the site for real residents.

If a resident's reservation record is accessed, the department needs to establish who accessed it and when, from a record that holds up even if someone gets onto the servers.

Everything must survive an availability zone going down.

## The Design

The architecture and the build order, reasoned out before touching the console, inside the 20 minutes.

**Public static content and the reservation system on one domain** \
One CloudFront distribution with two origins. The default behavior serves trail maps, park hours, and facility rules from an S3 bucket with Block Public Access on and a bucket policy pinning the distribution ARN. Path behaviors route the reservation section to a VPC origin pointing at an internal load balancer. One hostname, two destinations, decided by path.

**Servers unreachable in both directions** \
Instances in private subnets on a route table with no default route, so nothing leaves. The load balancer is internal with no public address, so there is nothing to reach from outside and nothing to bypass toward. AWS access comes through VPC endpoints: a gateway endpoint for S3 and interface endpoints for the SSM trio and CloudWatch Logs. The instance security group's egress is scoped to the endpoint group on 443 and to the S3 prefix list, since a gateway endpoint has no security group to reference. Administration is Session Manager, which opens no inbound port.

**An internet gateway attached but unused** \
A VPC origin requires an internet gateway attached to the VPC. It does not require a route pointing at one: the gateway denotes that the VPC can receive internet traffic, and CloudFront reaches the origin over a service-managed interface inside the VPC. The build therefore carries an attached gateway that no route table references, and no public subnets at all. The design initially included both before this was confirmed in the CloudFront documentation.

**Scripted traffic in bursts** \
A web ACL in us-east-1 with CloudFront scope, carrying a rate-based rule limiting requests per source address. Filtering happens at the edge, so a flood never reaches compute and never bills for it. WAF logs to a bucket carrying the required name prefix, in us-east-1 to match the web ACL's scope.

**Who accessed a reservation record and when** \
A resident opening a reservation record is an HTTP request reaching the application, so load balancer access logs carry the client address, the path, and the timestamp. Flow logs record the network layer underneath, answering a different question about the same event.

**A record that survives a compromise of the servers** \
Object Lock in governance mode on the access log bucket. The record lives off the instances entirely, and the instance role holds neither delete nor bypass permissions on it.

**An availability zone going down** \
Two availability zones with a private subnet in each, the load balancer spanning both, and the auto scaling group placing instances across both.

**Build order**

1. VPC, two private subnets across two AZs, route table, internet gateway attached
2. Instance and endpoint security groups referencing each other on 443, plus the S3 prefix list on instance egress. S3 gateway endpoint and the four interface endpoints with scoped policies
3. Static bucket with content
4. Launch template, auto scaling group, target group, ALB security group, internal load balancer, access log bucket with Object Lock
5. VPC origin, ALB inbound from the CloudFront service group, distribution with both origins and both behaviors
6. Web ACL with the rate-based rule, logging bucket, associated with the distribution
7. Flow logs, S3 server access logs, CloudFront logs

## What Building Revealed

**One pattern does not cover both the bare path and its subpaths** \
The reservation behavior was designed as `/reservations/*`, carried forward from how the static behavior was written in the [Integrated Build](https://github.com/LuMengistu/aws-cloud-security/tree/main/set1-architectural-foundations/integrated-build). A request for `/reservations` returned AccessDenied from S3: the bare path matched no pattern, so the default behavior claimed it and asked the bucket for an object that does not exist. A private bucket answers a missing object with AccessDenied instead of a 404, since a 404 would confirm what is and is not there. The apparent fix was `/reservations*`, which covers the bare path and everything under it in one behavior. That version also matches any path merely beginning with the string, so `/reservationsanything` would route to the reservation origin.

The version that matches all of the application and none of what it should not is two explicit behaviors, one for the exact path and one for everything beneath it. CloudFront evaluates behaviors in order and the default catches whatever no pattern claimed, so a pattern that is too narrow hands the request to the wrong origin. Whatever that origin returns reads as a problem with the origin instead of the routing. This was the first build where a behavior routed to compute instead of a bucket, which is what exposed it.

## Verification

**Both origins through one hostname** \
The default path serves the static content over HTTPS. `/reservations` and `/reservations/hey` both return an nginx 404 from the instance, which confirms the request traversed CloudFront, the VPC origin, the load balancer, and the target group and reached the web server. The 404 is the pass: a CloudFront error page would mean the request never arrived.

**Availability zone coverage** \
Both targets report healthy, one in us-west-2a and one in us-west-2b, with access logs subsequently delivering from both.

**Edge filtering** \
200 concurrent requests against the reservation path return CloudFront's block page. Subsequent single requests continue returning 403 until the trailing window rolls off, after which the path resolves normally again.

**Audit trail immutability** \
Access logs deliver from both availability zones on a five-minute cadence. A delivered object returns governance retention with a retain-until date seven days from write, and cannot be deleted inside that window without an explicit bypass the instance role does not hold.

**Logging** \
Flow logs deliver to CloudWatch Logs in a custom format carrying both original and post-translation addresses, flow direction, resource identifiers, and log status. S3 server access logs deliver with partitioned prefixes. CloudFront standard logs deliver to S3. The web ACL ARN is present on the distribution.

## Attacking the Controls

**Outbound isolation** \
From inside an instance over Session Manager, `curl` to a hostname and to a raw address both time out. Neither produces a flow log record: with no matching route the packet never leaves the instance, so nothing traverses the VPC to be logged. The raw address rules out name resolution as the cause.

**Lateral movement** \
A request from one private instance to the other on port 80 times out and produces a REJECT record with direction egress, protocol 6, from 10.0.1.5 to 10.0.2.94. The scoped instance egress refused the packet on the way out, not on arrival. An ICMP attempt to the same host produced the same egress REJECT, so the block is not protocol-specific.

**Service traffic stays private** \
`dig` on an AWS service hostname returns two addresses in the private subnet ranges, one per subnet, resolved by the VPC resolver. Those are the interface endpoint network interfaces, so the public AWS hostname resolves inside the VPC and the traffic never needs an internet path.

**Load balancer unreachable from outside** \
`dig` on the load balancer's DNS name resolves from the public internet and returns two private addresses, one per subnet. The request to it times out. The record is public and the addresses in it route nowhere from outside the VPC, so there is nothing to reach and nothing to bypass the edge toward.

**Origin unreachable directly** \
A request straight to the bucket's REST endpoint for an object that loads through the distribution returns 403 from S3. The bucket policy admits only the distribution, pinned by ARN, and a direct request carries no matching distribution ARN.

## Known Gaps

CloudFront terminates TLS at the edge and reaches the internal load balancer over HTTP on port 80. The connection stays inside the AWS network and never crosses the internet, but it carries the same reservation data the prompt describes as payment and personal information. Encrypting it means an HTTPS listener on the load balancer with a certificate in its own region and the VPC origin pointed at 443. This was a scope decision, not a constraint.

There is no reservation application. The instances serve nginx, so the access log establishes that a request for a path arrived and from where, not that a named resident opened a named record. The prompt's requirement is met at the layer this build covers, and naming the person needs the application to log its own authenticated identity.
