# Project 1: Hardened Host

**Compute Hardening | Keyless Access | Audit Logging**

A hardened EC2 instance with no open ports, no key pair, and no internet exposure. Access is through AWS Systems Manager only. Nginx is configured to self-heal, logs rotate on a schedule, Fail2ban monitors for brute force attempts, and every SSM session is logged to CloudWatch outside the instance. This foundation was built manually to internalize the core OS-level controls before moving to abstraction.

**Golden AMI:** ami-084672faad54ae817 | **Region:** us-west-2 | **Instance:** t3.micro | **OS:** Amazon Linux 2023

---

## What Was Built

**Zero inbound attack surface.** The security group has zero inbound rules. Port 22 is permanently closed. Connectivity is handled entirely through AWS Systems Manager Session Manager, with authentication through IAM and no network exposure of any kind.

**IMDSv2 enforced with hop limit 1.** The metadata service requires a session token before returning anything. The hop limit of 1 means the token response can only travel one network hop. A process inside a Docker container sits two hops away, so the token response never arrives and the container never gets credentials.

**Nginx self-heals on crash.** A systemd drop-in override configures `Restart=always` with a 5-second delay. If the process dies for any reason, systemd restores it automatically. The original unit file is untouched.

**Log rotation with safe rollover.** Logrotate rotates Nginx logs daily, retains 7 days, compresses with a one-cycle delay, and enforces a 10MB size cap. A `postrotate` directive sends USR1 to Nginx after each rotation so it starts writing to the new log file immediately.

**Fail2ban on SSH and Nginx.** Monitors auth logs for repeated failures. Bans offending IPs after 5 failures within a 10-minute window for 1 hour. Port 22 is permanently closed, so the SSH jail provides no active protection in this state. It stays enabled as a defensive habit — if port 22 were ever accidentally opened through misconfiguration or infrastructure drift, the jail is already in place.

**CloudWatch session audit trail.** Every SSM session is logged to `/ssm/sessions` outside the instance. An attacker with instance access cannot delete these logs. Every keystroke is recorded and tied to a session ID. The IAM policy uses two statements: `DescribeLogGroups` with a wildcard resource so the SSM agent can locate the group, and `CreateLogStream`, `PutLogEvents`, `DescribeLogStreams` scoped to the specific log group ARN.

**Docker installed and verified.** Docker is installed and `ssm-user` is added to the docker group. Required for the hop limit verification test.

**Golden AMI captured.** The instance was captured as `Cloud-Security-Hardened-Base` after full verification. Every project in Set 2 and beyond launches from this image.

---

## How to Use

Follow the manual checklist at the top of `setup.sh` for the console steps that cannot be scripted, including IAM role creation, CloudWatch log group setup, and Session Manager preferences. Then paste `setup.sh` into an SSM session on a fresh instance and run it.

To tear everything down:

```bash
bash ~/nuke.sh
```

The script requires typing `NUKE` to confirm before touching anything. It terminates all tagged instances, waits for full termination, deletes any detached EBS volumes tagged to the project, and releases any Elastic IPs tagged to the project. Every destructive action is printed to the terminal before it runs.

---

## Verification

**Nginx self-heal.** Killed with `sudo kill -9`. Confirmed new PID within 5 seconds via `ps aux | grep nginx`. Systemd created entirely new processes, not resumed ones.

**IMDSv2 enforcement.** Ran `curl -s -o /dev/null -w "%{http_code}" http://169.254.169.254/latest/meta-data/` directly from the instance. Returned `401`. No token, no data.

**Hop limit container test.** Ran the token request from inside a Docker container using `docker run --rm amazonlinux:2023 curl -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" http://169.254.169.254/latest/api/token`. After approximately 2 minutes: `curl: (56) Recv failure: Connection reset by peer`. The token request reached the metadata service but the response could not travel back through 2 hops. No token issued. Container locked out.

**CloudWatch logging.** Confirmed session commands visible in `/ssm/sessions` within seconds of session start, including typos recorded as backspace characters.

**Nuke and rebuild.** Ran `bash ~/nuke.sh` from local MacBook. Instance terminated, volumes cleaned, EIPs released. Launched a fresh instance, ran `setup.sh`, confirmed `nginx`, `fail2ban`, and `docker` all active and running.

---

## Known Gaps

This build has no WAF or CloudFront in front of Nginx. HTTP traffic reaches the instance directly with no layer 7 filtering. That is addressed in Project 2.

The instance runs in the default VPC with a public subnet. Private subnet architecture with VPC Endpoints for internal-only service traffic is built in Project 3.

Fail2ban covers HTTP basic auth only. More sophisticated brute force attempts against application endpoints are not covered by this configuration.

CloudWatch log retention is set to 7 days for this dev environment. Production compliance requirements would mandate longer retention depending on the applicable framework.
