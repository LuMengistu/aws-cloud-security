# VPC Defense

### Network Segmentation | Private Subnets | Offensive Validation
---

A private network where the instances serving internet traffic have no path to the internet themselves. An ALB in the public subnets is the only way in; VPC endpoints are the only way out, reaching AWS services over the backbone rather than through a gateway. Every packet decision is recorded in flow logs. The controls were then tested by attacking them from a compromised instance, and each result is documented against the control that produced it.

**VPC** · `10.0.0.0/16`, four subnets across two AZs \
**Region** · us-west-2 \
**Compute** · golden AMI from Hardened Host, launched by an Auto Scaling group into the private subnets

## What Was Built

**Private subnets defined by routing, not by label** \
A subnet is public or private only because of the route table it is associated with. The public route table carries `0.0.0.0/0` to the internet gateway; the private route table carries no internet route at all. Both private subnets are associated with the private table, verified in the association view rather than assumed, because a subnet named private that is wired to the public table is a public subnet with a misleading name and every control downstream of it is theater. The consequence is the point of the project: an attacker who lands on a private instance has code running and nowhere to send it. The packet leaves the process, the kernel finds no matching route, and it dies on the host. No tools can be pulled down, no data can be shipped out, no command channel can be established. The compromise stalls at the foothold.

**No NAT gateway** \
A NAT gateway would give private instances outbound internet while blocking inbound, which is the conventional answer and the wrong one here. It reintroduces exactly the egress path the private tier exists to remove, and it bills hourly. Because the instances launch from a golden AMI with everything already installed and reach AWS through endpoints, they need no general internet egress at all. Recorded as a security and cost decision rather than an omission. One consequence follows from it: with no NAT and no internet route, `dnf` package updates reach the instance only through the S3 gateway endpoint, which constrains how tightly that endpoint's policy can be scoped.

**VPC endpoints as the only path to AWS** \
Private instances still need Systems Manager to be reachable, CloudWatch Logs for the audit trail, and S3 for storage and packages. Endpoints provide that over Amazon's backbone without touching the public internet, and each one leads to a single service and dead-ends there. That is the property that makes them safe where a NAT gateway is not: the road exists, but it goes exactly one place. The S3 endpoint is a gateway type, which is a route added to the private route table and costs nothing. The `ssm`, `ssmmessages`, and `ec2messages` endpoints plus `logs` are interface types, each placing a network interface with a private IP into both private subnets. All three SSM endpoints are required together; missing any one produces a Session Manager connection failure with no error naming the cause. Private DNS is enabled on the interface endpoints so the standard AWS hostnames resolve to those private addresses, which means the SSM agent needs no reconfiguration at all: it asks for the public hostname it was built to ask for and receives a local address.

**Endpoint policies as a data perimeter** \
An endpoint ships with a full-access policy, which on the S3 endpoint means the road reaches every bucket in every AWS account. That is a live exfiltration path: an attacker on a private instance cannot phone home over the internet, but can copy data into a bucket they own in their own account. The policy closes it with `s3:ResourceAccount`, which evaluates the account that owns the bucket being touched and requires it to match this one. Two further statements exist because the Amazon Linux repositories and the SSM service buckets are AWS-owned and sit outside the account by definition, so the perimeter statement denies them and both `dnf` and the SSM agent break. Those are allowed by explicit ARN with `GetObject` and `ListBucket` on both the bare bucket and the object path, since the two actions evaluate against different ARN forms and `GetObject` alone passes a first read then fails on repository metadata. All three statements are Allow. A Deny would override the service allowances regardless of what else the policy permits. The four interface endpoints carry a simpler policy scoping them to principals in this account.

**The load balancer as the only ingress** \
The ALB lives in the public subnets and is the only resource in the build with a public address. It terminates the visitor's TLS connection using an ACM certificate, then opens its own separate connection inward to an instance on port 80, so the visitor and the instance never touch. The instance security group allows inbound 80 from the ALB's security group by reference rather than by CIDR. That distinction is the control: a CIDR rule admits anything in the range, while a group reference admits only resources carrying that group, and it survives instance replacement because a new instance inherits the group regardless of what IP it receives. Two rules are the entire perimeter. The ALB accepts the world on 443 and 80; the instances accept only the ALB. A second listener on 80 returns a 301 to HTTPS so nothing is served in the clear beyond the redirect itself.

**Instances that replace themselves** \
An Auto Scaling group maintains two instances, one per availability zone, launched from a template that pins the golden AMI, IMDSv2 with hop limit 1, and the instance security group. The template deliberately does not specify a subnet, because doing so overrides the group's placement and collapses both instances into a single zone. A target group health checks `/healthz`, the probe endpoint baked into the AMI in Hardened Host, and instances register and deregister with it automatically rather than by hand, since a manually registered instance ID is stale the moment the group replaces it. `audit.sh` verifies IMDSv2 enforcement and hop limit across every tagged instance rather than one, because the control has to hold across replacements to mean anything.

**Two log streams, deliberately separate** \
Flow logs capture every connection in the VPC to CloudWatch, filtered to all traffic rather than accepted traffic only, because the blocked attempts are the evidence the controls work. The format is custom rather than default: `flow-direction`, `instance-id`, and the packet-level source and destination addresses are omitted from the default and all four are needed to reconstruct an attack. Behind a load balancer, `srcaddr` shows the balancer rather than the originating client, while `pkt-srcaddr` preserves the real source. Separately, ALB access logs go to S3 with Object Lock in governance mode. Layer 7 request records and layer 3 packet decisions are kept in different streams on purpose, so application activity and network activity do not mix into one unauditable log.

**Every control tested by attacking it** \
Six attempts were run from a private instance treated as an already-compromised host, each recorded as what was tried, what was expected, what happened, and the evidence. Outbound internet failed with no flow log record at all, which is itself the evidence: with no matching route the packet never left the instance, so nothing traversed the VPC to be logged. Instance-to-instance traffic on the application port failed with a REJECT record, because that packet did leave, crossed the VPC, and was refused by the receiving security group. The same five-second timeout at the terminal, produced by two different mechanisms and distinguishable only in the logs. An out-of-account S3 write was denied by the endpoint policy's action scoping, though the account perimeter itself remains untested for want of a bucket in another account that would otherwise accept the write. `dig` on an AWS service hostname returned private endpoint addresses, confirming service traffic stays on the backbone. `aws sts get-caller-identity` hung, because no STS endpoint exists and there is no route to a public one, which means the instance credentials are stealable but nearly unusable from the instance itself. The container metadata attempt succeeded and is documented under Known Gaps.

## How to Use

Follow the console prerequisites in `setup.md` for the pieces that cannot be scripted: the VPC and subnets, the route tables and their associations, the internet gateway, the endpoints, the security groups, the launch template, the Auto Scaling group, the target group, and the load balancer. The policies, user data, format strings, and scripts those steps depend on are recorded there in full.

`setup.md` is a guided reference rather than a one-shot runnable script. Before use, substitute your own `<ACCOUNT_ID>`, `<VPC_ID>`, and access log bucket name. The VPC ID in particular changes on every rebuild and must be reconciled in `nuke.sh`.

Export the flow logs before tearing down. Teardown destroys the log group, and the Set 2 Flow Log Parser consumes those records as input.

To tear down, run `nuke.sh`. It requires typing `NUKE` to confirm. Order is enforced by AWS whether or not the script plans for it, and three things fail without explicit handling. Instances are still terminating when the Auto Scaling group's force-delete returns, and their network interfaces block subnet deletion. The target group's listener reference outlives the load balancer's own deletion wait. Security groups that reference each other cannot be deleted until the referencing rules are revoked first. The flow log group and the access log bucket sit outside the VPC and are not caught by VPC-scoped filters, and the bucket's Object Lock requires a governance bypass on every object version. The golden AMI, its snapshot, and `/ssm/sessions` are left intact as reused infrastructure.

## Verification

**Isolation** \
`curl` to a public hostname and to a raw IP both timed out after five seconds. The raw IP rules out DNS as the cause and proves there is no route. No flow log record was produced, consistent with a route-level drop rather than a filtered rejection.

**SSM over endpoints** \
Session Manager connected to an instance with no public IP and no internet route, confirming the three SSM endpoints, the endpoint security group, Private DNS, and the instance role all function together.

**Package path** \
`dnf update` completed through the S3 gateway endpoint with the scoped policy applied, confirming the repository bucket allowances are complete for the region.

**Security group referencing** \
An instance-to-instance request on the application port timed out and produced a REJECT record in the flow logs, showing source, destination, port, and direction. Blocked on ingress by the receiving instance's security group, which admits only the ALB's group.

**ALB path** \
The load balancer's DNS name served the nginx page over HTTPS, reached from the public internet, from instances that hold no public address and no route to one. A certificate warning is expected, since the certificate covers the domain rather than the AWS hostname.

**Private DNS** \
`dig` on an AWS service hostname returned two private addresses, one per private subnet, corresponding to the interface endpoint network interfaces.

**Flow log evidence** \
Both ACCEPT and REJECT records appear. The rejects include unsolicited internet scanning against the load balancer on ports the security group does not open, alongside the deliberately caused instance-to-instance rejection.

**IMDS audit** \
`audit.sh` reported IMDSv2 required and hop limit 1 across every tagged instance, with no drift.

**Clean-slate teardown** \
`nuke.sh` removed the full stack with no orphaned billable resources, verified by the VPC no longer existing and the load balancer, Auto Scaling group, and launch template queries returning empty.

## Known Gaps

A container running on an instance obtained the instance's IAM role credentials from the metadata service, not merely a session token. The response carried the full credential set, which is usable off the instance because AWS validates the credential rather than the caller's location. The AWS-documented control for this is an iptables rule in the `DOCKER-USER` chain, and it does not apply to this build for two independent reasons. The system uses the nftables backend, so the chain is incompatible with the iptables compatibility tool. More fundamentally, a packet capture taken on the host while a container requested the token showed every packet carrying the host's own interface and address. Rootless Docker rewrites container traffic to appear as host traffic, leaving no field in the packet that distinguishes the two, so a rule dropping traffic to the metadata address would take the SSM agent down with it. Container egress controls are deferred to Set 2, where orchestration-layer policy addresses this properly.

The endpoint policy's account perimeter is written but untested. Verifying it requires a bucket in another account that would otherwise accept the write, and the denials observed instead came from the policy's action scoping. An untested control is recorded as untested.

Flow logs are delivered to CloudWatch only. Production would additionally archive to S3 for cheaper long-term retention and cross-source analysis.

The instance role permits `logs:PutLogEvents` on `/ssm/sessions`. Credentials taken from the instance can therefore write into the session audit trail. They cannot delete from it, so the claim in Hardened Host that an attacker cannot delete session logs still holds, but injected entries make the record less trustworthy during an investigation than that claim implies.

There is no WAF on the load balancer. It is a valid direct target for one, unlike the S3 origin in Edge Hardening which required CloudFront in front of it, and adding it is a configuration step rather than an architectural change.
