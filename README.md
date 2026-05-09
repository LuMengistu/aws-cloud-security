# AWS Cloud Security

#### Infrastructure Hardening | Detection Engineering | Automated Governance

This roadmap is independently designed. Every gate, project, and pass condition was researched and built from scratch to reflect what the cloud security field  demands at a production level.

---

## How This Works

The roadmap is built around 13 gates, each one a specific technical domain: compute hardening, VPC defense, container security, incident response, and so on. Gates compound on each other. You cannot skip forward.

The work is organized into Sets. Each Set starts by rebuilding everything from prior Sets from memory, no references, no guides, faster and tighter than before. Then it adds the new gates introduced in that Set on top. The final project in every Set requires everything learned across that Set used simultaneously.

There are five Sets total. By the final one, the hardened EC2 instance from Set 1 is launching from a Terraform module, its IAM role bounded by Permission Boundaries, its logs flowing into an immutable bucket, deploying through a 13-stage automated pipeline. Same starting point. Five passes deeper.

---

## Core Philosophy

**Unrecognizable Depth** \
Every Set opens with a full rebuild of everything from prior Sets, executed from memory with no references. Set 2 starts by rebuilding the entire Set 1 stack from scratch, faster and tighter than the first time. Set 3 starts by rebuilding everything from Sets 1 and 2. By the final Set, the same hardened EC2 instance from week one is launching from a Terraform module, its IAM role bounded by Permission Boundaries, its logs flowing into an immutable bucket, deploying through a 13-stage pipeline. Same gate. Unrecognizable depth. That rebuild structure is what separates this from a list of projects. Every concept is reinforced repeatedly at increasing depth until the whole stack is second nature.

**The Set Capstone Project** \
Each Set ends with a capstone that is different from everything built inside it. The projects build skills one at a time. The capstone tests whether those skills hold against something new. After all projects are finished, a two-sentence prompt is revealed describing an unfamiliar build. It is completable only if the skills from the Set were actually learned and understood. No guides, no references, no help. The build is timed and executed on the spot. What worked and what broke gets documented and committed as a portfolio artifact.

**The Attacker's Mindset** \
Defense without an attacker's perspective is incomplete. Every control is validated by simulating real attacks and investigating the resulting logs to prove the defense holds.

**Zero-Footprint Hygiene** \
Every session ends with nuke.sh to terminate all resources, eliminate cost bleed, and enforce infrastructure purity.

**Verification-Driven** \
A control does not exist until it has been tested to failure and its recovery or block state is documented.

---

## The Roadmap

| Set | Focus |
|---|---|
| 1. Architectural Foundations | Host, network, and edge hardening |
| 2. Container Surface | Container hardening, runtime security, and secure supply chain |
| 3. Governed Infrastructure | IAM at scale, SCPs, and compliance as code |
| 4. Active Defense | Detection engineering, automated incident response, and AI endpoint security |
| 5. Pipeline Integrity | DevSecOps and OIDC-federated CI/CD |

---

## Current Progress

### Set 1: Architectural Foundations

🟢 **Project 1: The Hardened Host | Complete & Verified** \
IMDSv2 enforcement, SSM-only access, two-layer self-healing (systemd process supervision + watchdog health check), CloudWatch audit logging. Captured as a Golden AMI for all subsequent builds.

🟡 **Project 2: The Secure Edge | In Progress** \
CloudFront Origin Access Control, AWS WAF integration, Prowler-verified for zero critical findings.

⚪ **Project 3: VPC Defense | Upcoming** \
Isolated private subnets, VPC Endpoints for internal-only service traffic, purple team lateral movement validation.

🔵 **Set 1 Capstone Project | Pending** \
A two-sentence prompt revealed after all three projects are complete. It describes a build never attempted before, completable only with the skills developed in this Set. Closed book; no guides, no references, no help. 

---

## Repository Structure

Each project folder contains the scripts, automation, and documentation for that project. Contents grow in complexity as the roadmap progresses.

```
aws-cloud-security/
├── set1-architectural-foundations/
│   ├── project1-hardened-host/
│   ├── project2-secure-edge/
│   ├── project3-vpc-defense/
│   └── set1-capstone-project/
├── set2-container-surface/
│   ├── set1-memory-rebuild/
│   ├── project2-container-foundations/
│   ├── project3-hardened-orchestration/
│   ├── project4-container-escape/
│   └── set2-capstone-project/
└── ...
```
