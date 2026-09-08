# Integrated Build Setup

This rebuilds the edge, the private network, and the compute between them as one system. It is a guided reference, not a one-shot script: the VPC, endpoints, launch template, auto scaling group, load balancer, VPC origin, and distribution are console steps, and the blocks below are the policies and scripts those steps depend on. Teardown is a single script.

Before use, substitute your own values:
- `<ACCOUNT_ID>` - your 12-digit AWS account ID
- `<VPC_ID>` - changes on every rebuild; must match the `VPC_ID` in `nuke.sh`
- `<DIST_ID>` - your distribution ID; must match `DIST_ID` in `nuke.sh`
- `<BUCKET>` - the relevant bucket name

## Console Prerequisites

**Carried from Hardened Host**
- `p1-role` with `AmazonSSMManagedInstanceCore` plus the inline CloudWatch policy. The golden AMI does not carry the role, and Session Manager connects without the inline policy but writes no session logs.
- Log group `/ssm/sessions` with Session Manager preferences pointed at it and **enforce encryption off**. With it on, Session Manager refuses to write to a log group that has no customer-managed key, and the session hangs at connect with no shell.
- Golden AMI `ami-05e4c95d4bf1a0bfa`.

**Certificate**
- Request a public ACM certificate in **us-east-1**, covering the apex and www, DNS-validated at the registrar. CloudFront reads certificates only from us-east-1. Do not proceed until status is Issued.
- The load balancer needs no certificate. TLS terminates at the edge and the connection inward is private.

**VPC and subnets**
- VPC `p4-vpc`, CIDR `10.0.0.0/16`, created as **VPC only**. Tag it.
- Actions, Edit VPC settings, enable **DNS hostnames**. Private DNS on the interface endpoints will not accept without it.
- Four subnets tagged at creation:

| Name | AZ | CIDR |
|---|---|---|
| `p4-public-a` | us-west-2a | 10.0.1.0/24 |
| `p4-private-a` | us-west-2a | 10.0.2.0/24 |
| `p4-public-b` | us-west-2b | 10.0.3.0/24 |
| `p4-private-b` | us-west-2b | 10.0.4.0/24 |

- Internet gateway `p4-igw`, created then attached. It carries no traffic to the origin, but a VPC origin requires the VPC to have one attached.
- Route table `p4-public-rt`: `0.0.0.0/0` to `p4-igw`, associated with both public subnets.
- Route table `p4-private-rt`: no routes added, associated with both private subnets.
- Verify `p4-private-rt` shows only the local route before continuing.

**Security groups, in this order**
- `p4-endpoint-sg`: inbound HTTPS 443 from `p4-instance-sg` by reference. Delete the default egress rule.
- `p4-instance-sg`: no inbound yet. Two egress rules, both 443: one to `p4-endpoint-sg` by reference, one to the S3 prefix list (`pl-68a54001` in us-west-2, searchable in the destination field). A gateway endpoint has no security group, so S3 traffic matches nothing without the prefix list rule. Session Manager will still connect without it and only `dnf` will fail.
- `p4-alb-sg`: no inbound yet. Egress **port 80** to `p4-instance-sg` by reference. Not 443; the instances listen on 80.
- Then add to `p4-instance-sg`: inbound port 80 from `p4-alb-sg` by reference.
- The load balancer's inbound rule comes later, after the VPC origin exists.

**Endpoints**
- S3 **gateway** endpoint on `p4-private-rt`. The Interface variant of S3 sits directly above the Gateway one with an identical name; match on the Type column.
- Interface endpoints for `ssm`, `ssmmessages`, `ec2messages`, and `logs` in both private subnets, secured by `p4-endpoint-sg` with the default group unchecked, **Enable private DNS name** checked. All three SSM endpoints are required together and a missing one produces a connection failure with no error naming the cause.

**Static origin bucket**
- `p4-bucket-<ACCOUNT_ID>-us-west-2-an`, us-west-2, ACLs disabled, Block Public Access on all four settings, SSE-S3.
- Static website hosting **disabled**. That mode serves objects without evaluating the bucket policy, so origin access control has nothing to enforce and the lock silently does nothing.
- Create a folder `static/` and upload an `index.html` with identifiable content, so a response can be traced to this origin rather than the application.

**Compute**
- Launch template `p4-launch-template`: golden AMI, t3.micro, no key pair, `p4-instance-sg`, instance profile `p1-role`, IMDSv2 required, hop limit 1, metadata tags off.
- Subnet and AZ: **don't include**. The auto scaling group places instances; a pinned subnet overrides that and collapses both into one zone.
- User data below.
- Auto scaling group `p4-asg`: both private subnets, balanced best effort, desired/min/max 2. Tag it.
- Target group `p4-tg`: type Instance, HTTP port 80, VPC `p4-vpc`, health check path `/healthz`, healthy and unhealthy thresholds 2, timeout 5, interval 30, success code 200. Register **no targets**.
- Attach `p4-tg` to `p4-asg` from the group's Integrations tab, and enable **ELB health checks** there.

**Load balancer**
- Application Load Balancer `p4-alb`, scheme **Internal**, IPv4, VPC `p4-vpc`, both **private** subnets, security group `p4-alb-sg`.
- One listener: HTTP on port 80, forward to `p4-tg`. No certificate.
- Wait for state Active before creating the VPC origin.

**VPC origin**
- CloudFront, VPC origins, Create VPC origin. Select the load balancer's ARN.
- Protocol **HTTP only**, port 80. Match-viewer sends CloudFront at 443, where nothing is listening.
- Wait for status **Deployed**, up to 15 minutes.
- Creating it is what makes `CloudFront-VPCOrigins-Service-SG` appear in the account. Then add to `p4-alb-sg`: inbound port 80 from that group.

**Distribution**
- Create with the S3 bucket as its origin. The creation wizard accepts one origin only. Origin type Amazon S3, leave the option enabled that lets CloudFront update the bucket policy, take the recommended settings.
- Once it exists, Origins tab, Create origin, origin type **VPC origin**, select the one created above. Origin path empty.
- Behaviors tab: edit the default behavior to point at the VPC origin, cache policy `CachingDisabled` and origin request policy `AllViewer` since the origin is dynamic. Then create a second behavior, path pattern `/static/*`, origin the S3 one, `CachingOptimized`, allowed methods GET and HEAD.
- General settings: alternate domain names for apex and www, attach the us-east-1 certificate. Viewer protocol policy redirect HTTP to HTTPS.
- Apply the generated bucket policy to the S3 bucket. The condition pins the distribution ARN, so it can only be applied after the distribution exists.
- At the registrar: ALIAS record on the apex and CNAME on www, both pointing at the distribution domain name. A bare domain cannot be a CNAME.

**Web ACL**
- Region **us-east-1**, resource type CloudFront distributions.
- Managed rule group: AWS Core rule set. It covers cross-site scripting and several other classes but not SQL injection, which is a separate rule group.
- Rate-based rule `p4-rate-limit`: 50 requests per 5-minute window per source IP, action Block. Fifty is chosen so it can be tripped by hand; a production threshold comes from real traffic.
- Logging bucket `aws-waf-logs-p4-<ACCOUNT_ID>-us-east-1-an`. WAF rejects any bucket name without that prefix.
- Associate the web ACL with the distribution explicitly.

**Logging**
- Flow log on the VPC, filter **All**, 1-minute aggregation, to CloudWatch Logs with a new service role. That role is separate from the instance profile; it is assumed by the flow logs service, not by the instances. Format string below.
- Load balancer access log bucket created with **Object Lock enabled** at creation, which requires versioning and cannot be added later. SSE-S3; SSE-KMS is unsupported for this delivery and fails silently. Then Properties, Object Lock, Edit, default retention Governance, 7 days. Bucket policy below. Enable access logs on the load balancer with **no prefix**.
- CloudFront logs: use the **standard logging v2** path from the distribution's Logging tab, not the legacy option in distribution settings. Legacy requires ACLs on the destination bucket, which undoes the ACLs-disabled setting. Destination S3, format JSON, no partitioning, default fields.
- S3 server access logging on the static origin bucket, delivered to a bucket in the same region under prefix `s3-access/`, not replicated.

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

## Flow Log Export

Run before teardown. Teardown destroys the log group and the Set 2 Flow Log Parser consumes these records as input.

`--output text` places every record on one line. `--output json` piped through `jq` gives one record per line.

```bash
TZ=UTC date -j -f "%Y-%m-%d %H:%M:%S" "<DATE> <START>" +%s
TZ=UTC date -j -f "%Y-%m-%d %H:%M:%S" "<DATE> <END>" +%s

aws logs filter-log-events \
--log-group-name /vpc/flow-log \
--start-time <START_MS> --end-time <END_MS> \
--profile lu --region us-west-2 \
--query 'events[].message' \
--output json | jq -r '.[]' > p4-flowlogs.txt

wc -l p4-flowlogs.txt
grep -c ACCEPT p4-flowlogs.txt
grep -c REJECT p4-flowlogs.txt
```

Add three zeros to each epoch value for milliseconds. Confirm the deliberate rejections are present before destroying the source.

## After the Build

Run the verification checks: a private instance connects via Session Manager with no internet path, `dnf update` completes, `dig` on an AWS service hostname returns private addresses, both targets report healthy, the apex domain serves the application over HTTPS, `/static/index.html` serves from the bucket, an anonymous request to the bucket's REST endpoint returns 403, the load balancer's DNS name times out from outside the VPC, a payload matching the core rule set returns 403, the rate limit trips, and both ACCEPT and REJECT records appear in the flow logs.

Export the flow logs, then run `nuke.sh`.

Teardown order is enforced by dependencies. The edge goes first: disable the distribution and clear its web ACL association in one update, wait for it to redeploy without interrupting, then delete it with a fresh version identifier because the disable superseded the previous one. Then the web ACL, then every VPC origin.

Four things fail without explicit handling. Force-delete on the auto scaling group returns while instances are still terminating and their network interfaces block subnet deletion, so instance IDs are captured before the group is deleted. Endpoint network interfaces do not clear instantly and a subnet will not delete while one is attached, so the script polls. The target group's listener reference outlives the load balancer's own deletion wait, so the delete is retried. Security groups that reference each other cannot be deleted until every rule on all of them is revoked.

The flow log group and every bucket sit outside the VPC, so a VPC-scoped teardown leaves them running.

The golden AMI, its snapshot, the ACM certificates, and `/ssm/sessions` are left intact as reused infrastructure.
