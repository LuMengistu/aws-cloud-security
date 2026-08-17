# VPC Defense Setup

This rebuilds the private network and the compute behind it. It is a guided reference, not a one-shot script: the VPC, subnets, route tables, endpoints, launch template, ASG, and load balancer are console steps, and the blocks below are the policies and scripts those steps depend on. Teardown is a single script.

Before use, substitute your own values:
- `<ACCOUNT_ID>` - your 12-digit AWS account ID (appears in every policy and ARN)
- `<VPC_ID>` - your VPC ID (changes on every rebuild; must match the `VPC_ID` in `nuke.sh`)
- `<BUCKET>` - the ALB access log bucket name

## Console Prerequisites

**Carried from Hardened Host**
- `p1-role` with `AmazonSSMManagedInstanceCore` plus the inline CloudWatch policy. The golden AMI does not carry the role, and Session Manager connects without the inline policy but writes no session logs.
- Log group `/ssm/sessions` with Session Manager preferences pointed at it.
- Golden AMI `ami-05e4c95d4bf1a0bfa`.

**ACM certificate**
- Request a public certificate in us-west-2, DNS-validated at the registrar. CloudFront requires us-east-1; an ALB reads certificates only from its own region, so the Project 2 certificate cannot be reused.
- Namecheap auto-appends the domain, so the CNAME host is the random string only.

**VPC and subnets**
- Create `p3-vpc` at `10.0.0.0/16` using **VPC only**. The "VPC and more" wizard provisions a NAT gateway this build deliberately omits and wires route tables that need to be built by hand.
- Enable **DNS hostnames** on the VPC. Off by default on a manually created VPC, and Private DNS on the interface endpoints will not accept without it.
- Four subnets tagged at creation: `p3-public-a` (10.0.1.0/24, us-west-2a), `p3-private-a` (10.0.2.0/24, us-west-2a), `p3-public-b` (10.0.3.0/24, us-west-2b), `p3-private-b` (10.0.4.0/24, us-west-2b).
- Two AZs is mandatory, not stylistic. An ALB will not create with subnets in fewer than two.

**Gateway and route tables**
- Create `p3-igw`, then attach it to the VPC. Creation and attachment are separate steps.
- `p3-public-rt` with `0.0.0.0/0` to `p3-igw`, associated with both public subnets.
- `p3-private-rt` with no internet route, associated with both private subnets.
- Do not reuse the main route table. Verify `p3-private-rt` shows only the local route before continuing.
- No NAT gateway. Private instances reach AWS through endpoints; general internet egress is the phone-home path this build closes.

**Security groups**
- `p3-instance-sg` with no inbound rules and default egress. Inbound is added once the ALB SG exists.
- `p3-endpoint-sg` with inbound HTTPS 443 sourced from `p3-instance-sg` by reference, egress removed. Security groups are stateful, so replies to inbound connections flow back regardless, and an interface endpoint never initiates a connection of its own.
- `p3-alb-sg` with inbound 443 and 80 from `0.0.0.0/0`, egress 80 to `p3-instance-sg`. Both inbound rules are needed, because the port 80 listener performs the redirect and is blocked without its own rule.
- Then add inbound HTTP 80 to `p3-instance-sg` sourced from `p3-alb-sg` by reference. A CIDR rule would admit anything in the range; an SG reference survives instance replacement because a new instance inherits the group regardless of its IP.

**Endpoints**
- S3 gateway endpoint on `p3-private-rt`. The Interface variant of S3 sits directly above the Gateway one in the service list and bills hourly.
- Interface endpoints for `ssm`, `ssmmessages`, `ec2messages`, and `logs` in both private subnets, secured by `p3-endpoint-sg`, with **Enable private DNS name** checked. Session Manager requires all three SSM endpoints; missing one produces a connection failure with no error naming the cause.

**Compute and load balancer**
- Launch template `p3-launch-template`: golden AMI, t3.micro, no key pair, `p3-instance-sg`, `p1-role`, IMDSv2 required, hop limit 1, metadata tags off. Subnet and AZ deliberately not included, since pinning a subnet overrides the ASG and collapses everything into one AZ. User data block below.
- ASG `p3-asg` into both private subnets, balanced best effort, desired/min/max all 2.
- Target group `p3-tg` on HTTP:80, health check path `/healthz`, thresholds 2 and 2, timeout 5s, interval 30s, success code 200. Register no targets. Attach the group to the ASG so instances register and deregister as they are replaced. Enable ELB health checks on the ASG.
- ALB `p3-alb`, internet-facing, both public subnets, `p3-alb-sg`. Listener HTTPS:443 forwarding to `p3-tg` with the ACM certificate; listener HTTP:80 redirecting to 443 with status 301.

**Access log bucket**
- Create with **Object Lock enabled**, which requires versioning and cannot be added after creation. SSE-S3 only; KMS is unsupported for ALB access logs and fails delivery silently.
- Set a default retention rule of Governance, 7 days. Enabling Object Lock alone locks nothing.
- Enable access logs on the ALB with **no prefix**. AWS appends `AWSLogs` itself, and within a minute writes `ELBAccessLogTestFile` to validate the policy. Its presence is the confirmation; no traffic is needed.

**Flow logs**
- Flow log on the VPC, filter **All**, 1-minute aggregation, to CloudWatch log group `/vpc/flowlogs` with a new service role. Format string below.
- Filter All rather than Accept, because blocked attempts are the evidence the controls work.

## S3 Endpoint Policy

Three Allow statements, all Allow and never Deny. A Deny overrides the service allowances and breaks `dnf` and the SSM agent regardless of what else is permitted.

Statement one is the data perimeter. `s3:ResourceAccount` is the account that owns the bucket being touched, so a copy to a bucket in another account fails ownership and is denied by default, since endpoint policies are allow-list only.

Statements two and three exist because the Amazon Linux repos and the SSM service buckets are AWS-owned and sit outside the account by definition, so statement one denies them. Both actions are required: `GetObject` fetches packages, `ListBucket` reads the repo index, and they evaluate against different ARN forms. `GetObject` alone passes a first read and then fails on metadata resolution.

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
            "Action": [
                "s3:ListBucket",
                "s3:GetObject"
            ],
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
            "Action": [
                "s3:ListBucket",
                "s3:GetObject"
            ],
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

The same policy on all four interface endpoints. Deliberately permissive on Action and Resource, since tightening those blocks the SSM agent's own calls and costs access to the instances.

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

The ALB is not the principal. Log delivery is performed by a service principal, and `aws:SourceArn` scopes it to load balancers in this account and region. `ArnLike` with a wildcard is used rather than a specific ARN because the ALB's generated ID changes on every rebuild, which would silently stop log delivery until the policy was updated.

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

## Launch Template User Data

`firewalld` ships enabled in the golden AMI as a fail2ban dependency and drops ALB health checks on port 80. It was documented as harmless in Hardened Host under zero-inbound; that premise no longer holds once the ALB has to reach the instances. User data runs as root at boot, so no `sudo`.

```bash
#!/bin/bash
systemctl disable --now firewalld
```

## Flow Log Format

The default format omits `flow-direction`, `instance-id`, and the packet-level addresses. Behind the ALB, `srcaddr` shows the load balancer rather than the originating client, while `pkt-srcaddr` preserves the real source.

```
srcaddr dstaddr pkt-srcaddr pkt-dstaddr srcport dstport protocol action flow-direction vpc-id subnet-id instance-id start end bytes packets log-status
```

## audit.sh

Verifies IMDSv2 enforcement across every tagged instance. Run against the live ASG rather than a single instance, since the group replaces instances and the control has to hold across replacements.

```bash
#!/bin/bash
aws ec2 describe-instances \
--filters "Name=tag:Project,Values=Cloud-Security" \
--query "Reservations[].Instances[].[InstanceId, MetadataOptions.HttpTokens, MetadataOptions.HttpPutResponseHopLimit]" \
--output text --profile lu --region us-west-2 | while read -r id token hop; do
  if [ "$token" = "required" ] && [ "$hop" = "1" ]; then
    echo "$id PASS"
  else
    echo "$id FAIL: tokens=$token hop=$hop"
  fi
done
```

## Flow Log Export

Run before teardown. Teardown destroys the log group and the Set 2 Flow Log Parser consumes these records as input. Pull the purple team window specifically, since those records contain the rejects caused deliberately, which is what the parser is validated against.

`--output text` places every record on one line. `--output json` piped through `jq` gives one record per line, which is the format the parser expects. `filter-log-events` caps at 10,000 events or 1MB per call, so check the line count against the expected volume.

```bash
aws logs filter-log-events \
--log-group-name /vpc/flowlogs \
--start-time <EPOCH_MS> \
--end-time <EPOCH_MS> \
--profile lu --region us-west-2 \
--query 'events[].message' \
--output json | jq -r '.[]' > p3-flowlogs.txt
```

## After the Build

Run the verification checks: a private instance connects via Session Manager with no internet path, `dnf update` completes through the S3 endpoint, `dig` on an AWS service hostname returns private addresses, both targets report healthy, the ALB DNS name serves the page over HTTPS, and both ACCEPT and REJECT records appear in the flow logs. Export the flow logs, then run `nuke.sh` to tear down.

Teardown order is enforced by AWS whether or not the script plans for it. Three things fail without explicit handling: instances are still terminating when force-delete returns and their network interfaces block subnet deletion; the target group's listener reference outlives the ALB deletion wait; and security groups that reference each other cannot be deleted until the referencing rules are revoked. The flow log group and the access log bucket sit outside the VPC and are not caught by VPC-scoped filters, and the bucket's Object Lock requires `--bypass-governance-retention` on every object version.

The golden AMI, its snapshot, and `/ssm/sessions` are left intact as reused infrastructure.
