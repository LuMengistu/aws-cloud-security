## Set 1: Architectural Foundations

### Compute Hardening | Edge Security | Network Defense
---
Set 1 builds the infrastructure layer the rest of the roadmap depends on. A hardened compute instance with no open ports, self-healing services, and audit logging. A static site delivered through CloudFront with the origin permanently locked, WAF blocking at the edge, and zero critical findings verified by automated scan. A private network with no internet path for internal resources, traffic controlled at every layer, and a purple team exercise to verify every control holds.

## Projects

#### ● [Hardened Host](https://github.com/LuMengistu/aws-cloud-security/tree/main/set1-architectural-foundations/hardened-host) | Complete & Verified
A hardened EC2 instance with zero inbound rules, SSM-only access, two-layer nginx self-healing, log rotation, Fail2ban, and CloudWatch session auditing. Captured as a golden AMI that later builds launch from.

#### → Edge Hardening | In Progress

A static site behind CloudFront with S3 locked down, HTTPS enforced, WAF blocking at the edge, encryption, cross-region replication, and Prowler-verified zero critical findings.

#### ○ VPC Defense | Upcoming

A hardened VPC with isolated private subnets, no internet path for private instances, ALB and ASG in front, and a purple team exercise to verify every control holds.

#### ○ Set 1 Capstone | Pending

A timed capstone that combines the Set's skills into a single build, done with minimal references.
