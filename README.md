# AWS Cloud Security

**Infrastructure Hardening | Detection Engineering | Automated Governance**

This repository tracks a compounding security roadmap focused on building and defending production-grade AWS environments. Every project is built from first principles, tested to failure, and managed through a fully automated lifecycle.

---

## How This Works

I structured this roadmap around three concepts: Gates, Strata, and Sets.

**Gates** are the individual skill areas. Things like compute hardening, VPC defense, and container security. There are 13 gates across the full roadmap. Each one represents a specific technical concept that has to be built, attacked, and understood before moving forward.

**Strata** are groups of Gates that share a theme. Stratum I groups Gates 1 through 4 under Architectural Foundations. Stratum II groups Gates 5 and 6 under Container Surface. Each Stratum introduces new gates and raises the bar on everything that came before it.

**Sets** are the work that proves a Stratum is owned. Each Set covers exactly the same gates as its corresponding Stratum, no more and no less. Set 1 is how Stratum I gets completed. Set 2 is how Stratum II gets completed. A Set is a sequence of projects that always starts from Gate 1 and runs through every gate in that Stratum. Within a Set, each project builds on the one before it. The first project establishes the foundation. Each one after adds a new concept on top. The final project in every Set requires everything learned across that Set to be used simultaneously.

The simplest way to think about it: Gates are the individual skills. Strata organize those gates into focused phases. Sets are how each Stratum gets executed and proven. That cycle repeats five times, with each pass deeper than the last.

---

## Core Philosophy

**Unrecognizable Depth.** Every Set starts back at Gate 1 and runs through every gate up to and including the new ones introduced in that Set. The first time through, the focus is on building the foundation correctly. The second time through, everything from Set 1 gets rebuilt with the skills from Set 2 layered on top. The third time, Set 3 raises the bar again. What begins as a manually configured EC2 instance eventually becomes infrastructure that deploys through a hardened pipeline, enforced by policy at every layer, with automated incident response and a governed AI endpoint alongside it. Each pass builds on the last until the infrastructure from the first week and the final week share nothing but their starting point. That cycle ensures every concept, from the earliest gates to the most advanced, is reinforced repeatedly at increasing depth until the whole stack is second nature.

**The Stratum Pass.** Completing the projects in a Set does not earn the pass. Mastery is only proven when the instructions are no longer needed. Every Stratum ends with a timed, memory-only build from a vague prompt to prove the material is internalized without guides. The result is documented and stored as a portfolio artifact.

**The Attacker's Mindset.** Defense without an attacker's perspective is incomplete. Every control is validated by simulating real attacks and investigating the resulting logs to prove the defense holds.

**Zero-Footprint Hygiene.** Every session ends with `nuke.sh` to terminate all resources, eliminate cost bleed, and enforce infrastructure purity.

**Verification-Driven.** A control does not exist until it has been tested to failure and its recovery or block state is documented.

---

## The Roadmap

A Stratum is passed only when its associated Set can be deployed and defended simultaneously under the memory-only pass condition.

| Stratum | Focus |
|---|---|
| I. Architectural Foundations | Host, network, and edge hardening |
| II. Container Surface | Container hardening, runtime security, and secure supply chain |
| III. Governed Infrastructure | IAM at scale, SCPs, and compliance as code |
| IV. Active Defense | Detection engineering, automated incident response, and AI endpoint security |
| V. Pipeline Integrity | DevSecOps and OIDC-federated CI/CD |

---

## Current Progress: Set 1 — Architectural Foundations

🟢 **Project 1: The Hardened Host** | Complete & Verified
IMDSv2 enforcement, SSM-only access, systemd self-healing, CloudWatch audit logging. Captured as a Golden AMI for all subsequent builds.

🟡 **Project 2: The Secure Edge** | In Progress
CloudFront Origin Access Control, AWS WAF integration, Prowler-verified for zero critical findings.

⚪ **Project 3: VPC Defense** | Upcoming
Isolated private subnets, VPC Endpoints for internal-only service traffic, purple team lateral movement validation.

🔵 **Stratum I Pass** | Pending
Timed, memory-only rebuild of the full Set 1 architecture from a vague prompt. No guides, no console shortcuts. Pass condition is a fully hardened, functional environment with documented results.

---

## Repository Structure

```
aws-cloud-security/
├── set1-architectural-foundations/
│   ├── project1-hardened-host/
│   ├── project2-secure-edge/
│   ├── project3-vpc-defense/
│   └── stratum1-pass-record/
├── set2-container-surface/
│   ├── set1-memory-rebuild/
│   ├── project2-container-foundations/
│   ├── project3-hardened-orchestration/
│   ├── project4-container-escape/
│   └── stratum2-pass-record/
└── ...
```

Each project folder contains the scripts, automation, and documentation for that project. Contents grow in complexity as the roadmap progresses.
