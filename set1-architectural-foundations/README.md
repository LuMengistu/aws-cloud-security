# Set 1: Architectural Foundations

#### Compute Hardening | Secure Edge | Network Defense

Set 1 covers the first four gates and is where the foundation gets built and proven. Every project builds on the one before it. A hardened host with no open ports and self-healing services. A static site locked behind CloudFront with WAF blocking at the edge and direct S3 access permanently blocked. A VPC with isolated private subnets, no internet path for private instances, and an attacker's walkthrough of the network to verify every control holds. Nothing in the roadmap that follows works without this layer being correct. Every later Set rebuilds it from memory before adding anything new.

---

## The Projects

🟢 **Project 1: The Hardened Host | Complete & Verified** \
A hardened EC2 instance with zero inbound rules, SSM-only access, two-layer nginx self-healing, log rotation, Fail2ban, and CloudWatch session auditing. Captured as a Golden AMI for all subsequent builds.

🟡 **Project 2: The Secure Edge | In Progress** \
A static site behind CloudFront with S3 locked down, HTTPS enforced, WAF blocking at the edge, encryption, cross-region replication, and Prowler-verified zero critical findings.

⚪ **Project 3: VPC Defense | Upcoming** \
A hardened VPC with isolated private subnets, no internet path for private instances, ALB and ASG in front, and a purple team exercise to verify every control holds.

🔵 **Set 1 Capstone Project | Pending** \
A two-sentence prompt revealed after all three projects are complete. It describes a build never attempted before, completable only with the skills developed in this Set. Closed book; no guides, no references, no help.
