# Integrated Build

### Single Entry Point | Path-Based Routing | Private Origin
---

A single entry point serving both static content and a private application, where the load balancer has no public address and the origin cannot be reached except through the edge. CloudFront routes by path: static assets come from a locked S3 bucket, everything else from an internal Application Load Balancer reached over a private connection into the VPC. WAF filters at the edge. Five log streams record what happened at five different layers. The stack was then attacked from outside and from inside.

**VPC** · `10.0.0.0/16`, four subnets across two AZs \
**Region** · us-west-2, with the certificate in us-east-1 \
**Compute** · golden AMI from [Hardened Host](https://github.com/LuMengistu/aws-cloud-security/tree/main/set1-architectural-foundations/hardened-host), launched by an Auto Scaling group into the private subnets

## What Was Built

**One hostname, two origins** \
The distribution carries two origins and chooses between them by path. A behavior on `/static/*` sends requests to the S3 bucket; the default behavior sends everything else to the load balancer. That is what makes this one system rather than two sitting next to each other, and it is the piece neither [Edge Hardening](https://github.com/LuMengistu/aws-cloud-security/tree/main/set1-architectural-foundations/edge-hardening) nor [VPC Defense](https://github.com/LuMengistu/aws-cloud-security/tree/main/set1-architectural-foundations/vpc-defense) had on its own.

**The load balancer has no public address** \
It is internal, placed in the private subnets alongside the instances. Its DNS name resolves to `10.0.x.x` addresses that route nowhere from outside the VPC. CloudFront becomes the only way in as a property of the network rather than as a rule that has to hold.

**CloudFront reaches it through a VPC origin** \
A VPC origin is what bridges a public CDN to a private load balancer. AWS places a service-managed network interface inside the VPC and CloudFront connects over it, so the load balancer never needs an address on the internet. The origin protocol is HTTP on 80, matching the listener.

**No certificate below the edge** \
TLS terminates at CloudFront with an ACM certificate in us-east-1, the only region CloudFront reads from. The connection from CloudFront to the load balancer is private and runs plain HTTP, so the load balancer needs no certificate and no listener on 443. Certificate management stays in one place.

**The origin is locked to this distribution** \
The bucket has Block Public Access on all four settings and ACLs disabled, so nothing anonymous reaches it. The bucket policy grants read to the CloudFront service principal with a condition pinning the exact distribution ARN, so no other distribution can front it.

**Instances have no path out** \
Two instances from the golden AMI, one per AZ, in subnets whose route table carries no default route. They reach AWS services through a gateway endpoint for S3 and interface endpoints for the SSM trio and CloudWatch Logs. The instance security group's egress is scoped rather than allow-all: 443 to the endpoint security group, and 443 to the S3 prefix list. Two rules because a gateway endpoint has no security group to reference.

**Two rules are the whole ingress perimeter** \
The load balancer accepts port 80 from the CloudFront service-managed security group, which exists only once a VPC origin has been created. The instances accept port 80 from the load balancer's group by reference. Nothing else reaches either. A group reference rather than a CIDR means the rule survives instance replacement, since a new instance inherits the group whatever address it receives.

**Five log streams, kept apart** \
CloudFront logs record what the edge served, and WAF logs record what it blocked and which rule matched. Load balancer access logs record what reached the application, delivered to a bucket with Object Lock in governance mode so the record cannot be removed by anyone who compromises the account. VPC flow logs record connection-level decisions inside the network, in a custom format carrying the packet-level addresses that a default format omits. S3 server access logs record reads against the static origin. A request blocked at the edge appears in the first stream and is absent from the second, and that absence is the evidence it never reached compute.

**Attacked from both directions** \
Nine attempts, four from outside and five from a private instance treated as already compromised. The outside half is what neither prior project could test: Edge Hardening had no compute to bypass toward, VPC Defense had no edge to bypass. The bypass question only exists once both are present.

## How to Use

Follow the console prerequisites in `setup.md`. The network, endpoints, launch template, auto scaling group, load balancer, and distribution are console steps; the policies, scripts, and format strings they depend on are recorded there in full.

`setup.md` is a guided reference rather than a runnable script. Substitute your own account ID, VPC ID, and bucket names before use. The VPC ID changes on every rebuild and must be reconciled in `nuke.sh`.

Export the flow logs before tearing down. Teardown destroys the log group, and the Set 2 Flow Log Parser consumes those records as input. Use `--output json` piped through `jq -r` rather than `--output text`, which places every record on one line.

To tear down, run `nuke.sh`. It requires typing `NUKE` to confirm. The edge goes first because the distribution holds the VPC origins and each VPC origin references into the VPC. Disabling the distribution requires waiting for it to redeploy, which can take fifteen minutes and must not be interrupted, and the delete afterward needs a fresh version identifier because the disable superseded the previous one. Four things then fail without explicit handling: force-delete on the auto scaling group returns while instances are still terminating and their network interfaces block subnet deletion; endpoint network interfaces do not clear instantly; the target group's listener reference outlives the load balancer's own deletion wait; and security groups that reference each other cannot be deleted until every rule is revoked. The golden AMI, its snapshot, and `/ssm/sessions` are left intact.

## Verification

**Both origins through one hostname** \
The apex domain serves the application over HTTPS from the load balancer. A request to `/static/index.html` serves from the bucket. Same hostname, two destinations, decided by path.

**Origin unreachable directly** \
An anonymous request to the bucket's REST endpoint for the same object returns AccessDenied, while that object loads through the distribution. The load balancer's DNS name resolves to private addresses and times out from outside the VPC.

**Edge filtering** \
A payload matching the managed core rule set returns 403 from CloudFront. Two hundred concurrent requests trip the rate-based rule, and the block persists on subsequent normal requests until the five-minute window rolls off.

**Isolation from inside** \
An instance reaches Session Manager and completes `dnf update` with no internet route. Outbound requests to a hostname and to a raw IP both time out and produce no flow log record. With no matching route the packet never leaves the instance, so nothing traverses the VPC to be logged. The raw IP rules out DNS as the cause.

**Instance-to-instance blocked on egress** \
A request from one private instance to the other on port 80 timed out and produced a REJECT record with direction `egress`. The scoped instance egress refused the packet on the way out rather than on arrival, which is a different control from the one that caught the same attempt in VPC Defense.

**Service traffic stays private** \
`dig` on an AWS service hostname returns two private addresses, one per private subnet, corresponding to the interface endpoint network interfaces.

**Logging** \
All four streams deliver. The load balancer's validation test file appears in its bucket within a minute of enabling access logs, confirming the bucket policy before any traffic arrives.

**Clean teardown** \
`nuke.sh` removes the distribution, web ACL, VPC origins, compute, network, and every bucket, verified by the VPC no longer existing and the load balancer, auto scaling group, and launch template queries returning empty.

## Known Gaps

The endpoint policy's account perimeter is written but untested, for the second build running. Verifying `s3:ResourceAccount` requires a bucket in another account that would otherwise accept the write. The denials observed came from action scoping on the AWS-owned buckets instead, which is a different statement doing the work.

The web ACL carries the managed core rule set, which covers cross-site scripting and several other classes but not SQL injection. That lives in a separate rule group which is not attached, so a SQL injection payload passes the edge. Rule coverage is a configuration decision, and having WAF says nothing about which attack classes are covered.

The rate limit is set at 50 requests per five minutes so it can be tripped by hand during testing. A production threshold would be derived from real traffic, where a single page load pulls dozens of requests from one address.

Container egress control remains unresolved, carried forward from VPC Defense. Rootless Docker rewrites container traffic to appear as host traffic, leaving no packet field to distinguish the two, and the nftables backend makes the AWS-documented iptables chain unaddressable. Addressed at the orchestration layer in Set 2.

Inbound network ACL rules are not evaluated on the CloudFront to VPC origin path, so subnet-level rules cannot restrict edge traffic reaching the origin. Security groups are the only inbound network control there. Outbound rules still govern the return path and must permit ephemeral ports.

The five log streams have no correlation between them. Answering a question that spans layers means querying each separately and matching timestamps by hand. Normalized logging arrives in Set 4.

At-rest KMS encryption on the session log group is deferred, carried forward from Hardened Host. Session Manager will not write once enforce-encryption is enabled unless a customer-managed key is attached.

The application is nginx serving a placeholder page. Nothing behind the load balancer generates dynamic content or holds data, so the path-based routing demonstrates the mechanism rather than a real application boundary.
