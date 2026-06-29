# AWS Cloud Security

### Infrastructure Hardening | Detection Engineering | Automated Governance
---
A cloud security engineering roadmap built through hands-on AWS projects. Each project builds the infrastructure, then validates the controls through attack simulation and verification.

The roadmap is organized into five Sets that build on one another. Set 1 hardens the host, edge, and network. Later Sets add containers, infrastructure as code, detection and response, and AI endpoint security. By Set 5, the hardened EC2 instance from Set 1 is deployed through Terraform, governed by Permission Boundaries, logged to immutable S3, and delivered through a 13-stage CI/CD pipeline. Same starting point, five passes deeper.

Each Set ends with a timed capstone that combines the Set's skills into a single build, done with minimal references.

## Roadmap Structure

| Set | Focus |
|-----|-------|
| 1. Architectural Foundations | Host, network, and edge hardening |
| 2. Container Surface | Container hardening, runtime security, and secure supply chain |
| 3. Governed Infrastructure | IAM at scale, SCPs, and compliance as code |
| 4. Active Defense | Detection engineering, automated incident response, and AI endpoint security |
| 5. Pipeline Integrity | DevSecOps and OIDC-federated CI/CD |

## Current Progress

### [Set 1: Architectural Foundations](https://github.com/LuMengistu/aws-cloud-security/tree/main/set1-architectural-foundations)

#### ● [Hardened Host](https://github.com/LuMengistu/aws-cloud-security/tree/main/set1-architectural-foundations/hardened-host) | Complete & Verified
IMDSv2 enforcement, SSM-only access, two-layer self-healing (systemd process supervision + watchdog health check), CloudWatch audit logging. Captured as a golden AMI for all subsequent builds.

#### → Edge Hardening | In Progress
CloudFront Origin Access Control, AWS WAF integration, Prowler-verified for zero critical findings.

#### ○ VPC Defense | Upcoming
Isolated private subnets, VPC Endpoints for internal-only service traffic, purple team lateral movement validation.

#### ○ Set 1 Capstone | Pending
A timed capstone that combines the Set's skills into a single build, done with minimal references.

## Repository Structure

```
aws-cloud-security/
├── set1-architectural-foundations/
│   ├── hardened-host/
│   ├── edge-hardening/
│   ├── vpc-defense/
│   └── set1-capstone/
├── set2-container-surface/
│   ├── set1-rebuild/
│   ├── image-hardening/
│   ├── cluster-admission/
│   ├── container-escape/
│   └── set2-capstone/
└── ...
```
