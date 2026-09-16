# Set 1 Capstone Setup

This rebuilds the county parks stack: a public static site and a private reservation application behind one CloudFront distribution. It is a guided reference, not a one-shot script. The VPC, endpoints, launch template, auto scaling group, load balancer, VPC origin, distribution, and web ACL are console steps, and the blocks below are the policies and scripts those steps depend on. Teardown is a single script.

Before use, substitute your own values:
- `<ACCOUNT_ID>` - your 12-digit AWS account ID
- `<VPC_ID>` - changes on every rebuild; must match the `VPC_ID` in `nuke.sh`
- `<DIST_ID>` - your distribution ID; must match `DIST_ID` in `nuke.sh`
- `<BUCKET>` - the relevant bucket name

## Console Prerequisites

**Carried from [Hardened Host](https://github.com/LuMengistu/aws-cloud-security/tree/main/set1-architectural-foundations/hardened-host)**
- `p1-role` with `AmazonSSMManagedInstanceCore` plus the inline CloudWatch policy. The golden AMI does not carry the role, and Session Manager connects without the inline policy but writes no session logs.
- Log group `/ssm/sessions` with Session Manager preferences pointed at it and **enforce encryption off**. With it on, Session Manager refuses to write to a log group that has no customer-managed key, and the session hangs at connect with no shell.
- Golden AMI `ami-05e4c95d4bf1a0bfa`.

**Certificate**
- A public ACM certificate in **us-east-1**, covering the apex and www, DNS-validated at the registrar. CloudFront reads certificates only from us-east-1. Do not proceed until status is Issued.
- The load balancer needs no certificate. TLS terminates at the edge and the connection inward is private.

**VPC and subnets**
- VPC `lu-vpc`, CIDR `10.0.0.0/16`, created as **VPC only**. Tag it.
- Actions, Edit VPC settings, enable **DNS hostnames**. Private DNS on the interface endpoints will not accept without it.
- Two subnets tagged at creation:

| Name | AZ | CIDR |
|---|---|---|
| `lu-private-a` | us-west-2a | 10.0.1.0/24 |
| `lu-private-b` | us-west-2b | 10.0.2.0/24 |

- Internet gateway `lu-igw`, created then attached. Add no route to it. An attached gateway is a prerequisite for a VPC origin; it denotes that the VPC can receive internet traffic and is never used to route to the origin. Public subnets are not needed for this reason and are not created.
- Route table `lu-private-rt`: no routes added, associated with both subnets.
- Verify it shows only the local route before continuing.

**Security groups, in this order**
- `lu-endpoint-sg`: inbound HTTPS 443 from `lu-instance-sg` by reference. Delete the default egress rule.
- `lu-instance-sg`: no inbound yet. Two egress rules, both 443: one to `lu-endpoint-sg` by reference, one to the S3 prefix list (`pl-68a54001` in us-west-2, searchable in the destination field). A gateway endpoint has no security group, so S3 traffic matches nothing without the prefix list rule. Session Manager will still connect without it and only `dnf` will fail.
- `lu-alb-sg`: no inbound yet. Egress **port 80** to `lu-instance-sg` by reference. Not 443; the instances listen on 80.
- Then add to `lu-instance-sg`: inbound port 80 from `lu-alb-sg` by reference.
- The load balancer's inbound rule comes later, after the VPC origin exists.

**Endpoints**
- S3 **gateway** endpoint on `lu-private-rt`. The Interface variant of S3 sits directly above the Gateway one with an identical name; match on the Type column.
- Interface endpoints for `ssm`, `ssmmessages`, `ec2messages`, and `logs` in both subnets, secured by `lu-endpoint-sg` with the default group unchecked, **Enable private DNS name** checked. All three SSM endpoints are required together and a missing one produces a connection failure with no error naming the cause.

**Static origin bucket**
- `lu-bucket-<ACCOUNT_ID>-us-west-2-an`, us-west-2, ACLs disabled, Block Public Access on all four settings, SSE-S3.
- Create a folder `static/` and upload an `index.html` with identifiable content, so a response can be traced to this origin rather than the application.

**Compute**
- Launch template `lu-launch-template`: golden AMI, t3.micro, no key pair, `lu-instance-sg`, instance profile `p1-role`, IMDSv2 required, hop limit 1, metadata tags off.
- Subnet and AZ: **don't include**. The auto scaling group places instances; a pinned subnet overrides that and collapses both into one zone.
- User data below.
- Auto scaling group `lu-asg`: both subnets, balanced best effort, desired/min/max 2. Tag it.
- Target group `lu-target-group`: type Instance, HTTP port 80, VPC `lu-vpc`, health check path `/healthz`, healthy and unhealthy thresholds 2, timeout 5, interval 30, success code 200. Register **no targets**. Create this under EC2, Load Balancing, Target groups.
- Attach `lu-target-group` to `lu-asg` from the group's Integrations tab, and enable **ELB health checks** there.

**Load balancer**
- Application Load Balancer `lu-alb`, scheme **Internal**, IPv4, VPC `lu-vpc`, both subnets, security group `lu-alb-sg`.
- One listener: HTTP on port 80, forward to `lu-target-group`. No certificate.
- Wait for state Active before creating the VPC origin.

**VPC origin**
- CloudFront, VPC origins, Create VPC origin. Select the load balancer's ARN.
- Protocol **HTTP only**, port 80. Match-viewer sends CloudFront at 443, where nothing is listening.
- Wait for status **Deployed**, up to 15 minutes.
- Creating it is what makes `CloudFront-VPCOrigins-Service-SG` appear in the account. Then add to `lu-alb-sg`: inbound port 80 from that group.

**Distribution**
- Create with the S3 bucket as its origin. The creation wizard accepts one origin only. Origin type Amazon S3, leave the option enabled that lets CloudFront update the bucket policy, take the recommended settings.
- Origin path empty. The `static/` prefix is carried by the default root object instead; setting both would make CloudFront ask the bucket for `static/static/index.html`.
- General settings: default root object `static/index.html`.
- Once it exists, Origins tab, Create origin, origin type **VPC origin**, select the one created above. Origin path empty.
- Behaviors tab: the default behavior stays on the S3 origin with `CachingOptimized`, serving the public park information. Then create **two** behaviors to the VPC origin, path patterns `/reservations` and `/reservations/*`, both `CachingDisabled` with origin request policy `AllViewer` since the origin is dynamic.
- Two behaviors and not one. `/reservations/*` alone leaves the bare path falling through to the default behavior and into the bucket, which answers a missing object with AccessDenied and sends you looking at the bucket policy. `/reservations*` covers both but also matches `/reservationsanything`.
- General settings: alternate domain names for apex and www, attach the us-east-1 certificate. Viewer protocol policy redirect HTTP to HTTPS.
- Apply the generated bucket policy to the S3 bucket. The condition pins the distribution ARN, so it can only be applied after the distribution exists.
- At the registrar: ALIAS record on the apex and CNAME on www, both pointing at the distribution domain name. A bare domain cannot be a CNAME.

**Web ACL**
- Region **us-east-1**, resource type CloudFront distributions. The region must match the scope.
- Rate-based rule `lu-rate-limit`: 50 requests per 5-minute window per source IP, action Block. Fifty is chosen so it can be tripped by hand; a production threshold comes from real traffic.
- Logging bucket `aws-waf-logs-lu-<ACCOUNT_ID>-us-east-1-an`. WAF rejects any bucket name without that prefix.
- Associate the web ACL with the distribution explicitly. Creating it protects nothing until it is attached.

**Logging**
- Flow log on the VPC, filter **All**, 1-minute aggregation, to CloudWatch Logs at `/vpc/flow-logs` with a new service role. That role is separate from the instance profile; it is assumed by the flow logs service, not by the instances. Format string below.
- Load balancer access log bucket `lu-alb-access-logs-<ACCOUNT_ID>-us-west-2-an`, created with **Object Lock enabled** at creation, which requires versioning and cannot be added later. SSE-S3; SSE-KMS is unsupported for this delivery and fails silently. Then Properties, Object Lock, Edit, default retention Governance, 7 days. Bucket policy below. Enable access logs on the load balancer with **no prefix**.
- CloudFront logs to `lu-cloudfront-access-logs-<ACCOUNT_ID>-us-west-2-an`: use the **standard logging v2** path from the distribution's Logging tab, not the legacy option in distribution settings. Legacy requires ACLs on the destination bucket, which undoes the ACLs-disabled setting. Destination S3, format JSON, no partitioning, default fields.
- S3 server access logging on the static origin bucket, delivered to `lu-s3-access-logs-<ACCOUNT_ID>-us-west-2-an` in the same region, partitioned prefix by event time, not replicated.

## S3 Endpoint Policy

Three Allow statements.

Statement one is the account perimeter. `s3:ResourceAccount` is the account that owns the bucket being touched.

Statements two and three cover buckets AWS owns, which sit outside the account by definition and are denied by statement one. Both actions are required and each bucket appears twice: the bare ARN for `ListBucket`, the `/*` form for `GetObject`. `GetObject` alone passes a first read and then fails on repository metadata.

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowOwnAccountBuckets",
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:*",
            "Resource": "*",
            "Condition": {
                "StringEquals": {
                    "s3:ResourceAccount": "<ACCOUNT_ID>"
                }
            }
        },
        {
            "Sid": "AllowPackageManagerAccess",
            "Effect": "Allow",
            "Principal": "*",
            "Action": ["s3:ListBucket", "s3:GetObject"],
            "Resource": [
                "arn:aws:s3:::al2023-repos-us-west-2-de612dc2",
                "arn:aws:s3:::al2023-repos-us-west-2-de612dc2/*",
                "arn:aws:s3:::al2023-us-west-2",
                "arn:aws:s3:::al2023-us-west-2/*",
                "arn:aws:s3:::amazonlinux-2-repos-us-west-2",
                "arn:aws:s3:::amazonlinux-2-repos-us-west-2/*",
                "arn:aws:s3:::amazonlinux.us-west-2.amazonaws.com",
                "arn:aws:s3:::amazonlinux.us-west-2.amazonaws.com/*",
                "arn:aws:s3:::packages.us-west-2.amazonaws.com",
                "arn:aws:s3:::packages.us-west-2.amazonaws.com/*",
                "arn:aws:s3:::repo.us-west-2.amazonaws.com",
                "arn:aws:s3:::repo.us-west-2.amazonaws.com/*"
            ]
        },
        {
            "Sid": "AllowSSMAgentPatchManagerAccess",
            "Effect": "Allow",
            "Principal": "*",
            "Action": ["s3:ListBucket", "s3:GetObject"],
            "Resource": [
                "arn:aws:s3:::aws-ssm-us-west-2",
                "arn:aws:s3:::aws-ssm-us-west-2/*",
                "arn:aws:s3:::amazon-ssm-us-west-2",
                "arn:aws:s3:::amazon-ssm-us-west-2/*",
                "arn:aws:s3:::amazon-ssm-packages-us-west-2",
                "arn:aws:s3:::amazon-ssm-packages-us-west-2/*",
                "arn:aws:s3:::aws-ssm-distributor-file-us-west-2",
                "arn:aws:s3:::aws-ssm-distributor-file-us-west-2/*",
                "arn:aws:s3:::aws-ssm-document-attachments-us-west-2",
                "arn:aws:s3:::aws-ssm-document-attachments-us-west-2/*",
                "arn:aws:s3:::patch-baseline-snapshot-us-west-2",
                "arn:aws:s3:::patch-baseline-snapshot-us-west-2/*",
                "arn:aws:s3:::us-west-2-birdwatcher-prod",
                "arn:aws:s3:::us-west-2-birdwatcher-prod/*",
                "arn:aws:s3:::aws-patch-manager-us-west-2-34d7f99f8",
                "arn:aws:s3:::aws-patch-manager-us-west-2-34d7f99f8/*",
                "arn:aws:s3:::amazoncloudwatch-agent-us-west-2",
                "arn:aws:s3:::amazoncloudwatch-agent-us-west-2/*",
                "arn:aws:s3:::amazoncloudwatch-agent",
                "arn:aws:s3:::amazoncloudwatch-agent/*"
            ]
        }
    ]
}
```

## Interface Endpoint Policy

The same policy on all four. Permissive on Action and Resource; tightening those blocks the SSM agent's own calls and costs access to the instances.

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowOwnAccountPrincipals",
            "Effect": "Allow",
            "Principal": "*",
            "Action": "*",
            "Resource": "*",
            "Condition": {
                "StringEquals": {
                    "aws:PrincipalAccount": "<ACCOUNT_ID>"
                }
            }
        }
    ]
}
```

## ALB Access Log Bucket Policy

Log delivery is performed by a service principal, not the load balancer itself. `ArnLike` with a wildcard rather than a specific ARN, because the load balancer's generated ID changes on every rebuild and a pinned ARN silently stops delivery.

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowALBAccessLogWrite",
            "Effect": "Allow",
            "Principal": {
                "Service": "logdelivery.elasticloadbalancing.amazonaws.com"
            },
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::<BUCKET>/AWSLogs/<ACCOUNT_ID>/*",
            "Condition": {
                "ArnLike": {
                    "aws:SourceArn": "arn:aws:elasticloadbalancing:us-west-2:<ACCOUNT_ID>:loadbalancer/*"
                }
            }
        }
    ]
}
```

AWS writes `ELBAccessLogTestFile` within a minute of enabling logging. Its presence confirms the policy without waiting for traffic.

Object Lock is confirmed on a delivered object, not on the bucket. `get-object-lock-configuration` states the rule; `get-object-retention` on a key states whether it applied. Default retention takes effect at write time, so objects delivered before it was set stay unlocked.

## Launch Template User Data

`firewalld` ships enabled in the golden AMI as a fail2ban dependency and drops health checks on port 80. The shebang is required; without it the block is not recognized as a script and never runs, and the failure surfaces as unhealthy targets with `Target.Timeout`.

```bash
#!/bin/bash
systemctl disable --now firewalld
```

## Flow Log Format

The default format omits the packet-level addresses, `flow-direction`, and `instance-id`.

```
srcaddr dstaddr pkt-srcaddr pkt-dstaddr srcport dstport protocol action flow-direction vpc-id subnet-id instance-id start end bytes packets log-status
```

## After the Build

Run the verification checks: both behaviors reaching nginx, the default behavior serving the static page, both targets healthy across two AZs, the rate rule blocking under load, access logs delivering from both zones with a retention date on the object, and all four log streams delivering.

Then the control tests: outbound to a hostname and to a raw address, one instance to the other on port 80, `dig` on an AWS service hostname, the load balancer's DNS name from outside the VPC, and the bucket's REST endpoint directly.

To tear down, run `nuke.sh`. Teardown order is enforced by dependencies. The edge goes first: disable the distribution and clear its web ACL association in one update, wait for it to redeploy without interrupting, then delete it with a fresh version identifier because the disable superseded the previous one. Then the web ACL, then the VPC origin.

Four things fail without explicit handling. Force-delete on the auto scaling group returns while instances are still terminating and their network interfaces block subnet deletion, so instance IDs are captured before the group is deleted. Endpoint network interfaces do not clear instantly and a subnet will not delete while one is attached, so the script polls. The target group's listener reference outlives the load balancer's own deletion wait, so the delete is retried. Security groups that reference each other cannot be deleted until every rule on all of them is revoked.

The flow log group and every bucket sit outside the VPC, so a VPC-scoped teardown leaves them running.

The golden AMI, its snapshot, the ACM certificates, and `/ssm/sessions` are left intact as reused infrastructure.
