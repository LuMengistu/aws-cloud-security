# Hardened Host
### Compute Hardening | Keyless Access | Audit Logging
---

A hardened EC2 instance with no open ports, no key pair, and no internet exposure. Access is through AWS Systems Manager only. Nginx runs two-layer self-healing that catches both process death and degraded-but-alive state. Logs rotate on schedule. Every SSM session is logged to CloudWatch off the instance. Containers run rootless under a dedicated identity so the interactive identity never holds host root.

**Golden AMI** · `golden-ami` \
**Region** · us-west-2 \
**OS** · Amazon Linux 2023

## What Was Built

**Zero inbound attack surface** \
The security group has zero inbound rules. Port 22 is permanently closed. The SSM Agent initiates all connections outbound, so no inbound path is needed and the empty inbound ruleset is complete rather than partial. Default allow-all egress is left in place because the agent needs outbound 443 to reach Systems Manager. Tightening egress to the SSM endpoints is a documented temporary decision deferred to Project 3: VPC Defense.

**IMDSv2 enforced with hop limit 1** \
The metadata service requires a session token before returning anything. Hop limit 1 is correct for a host that runs workloads directly. The limit is topology-dependent, not universal: a container or pod network reaching IMDS through IRSA needs hop limit 2, a distinction that carries into Set 2. On this build, hop limit 1 did not block rootless containers from reaching IMDS, documented in the container IMDS check under Verification and under Known Gaps.

**Nginx self-heals across two failure modes** \
Self-healing means recovering from degraded state, not just process death. A process can be alive and still serving errors, which systemd cannot see, so two mechanisms work together. Layer 1 is a systemd drop-in with `Restart=on-failure` and `RestartSec=5s` in `[Service]`, plus `StartLimitIntervalSec=60` and `StartLimitBurst=3` in `[Unit]`. `on-failure` is used rather than `always`, because `always` fights clean stops and can infinite-loop on a config error. The StartLimit math holds deliberately: the interval must exceed RestartSec times burst, so 60 exceeds 15, or a broken nginx crash-loops forever. \
Layer 2 is a watchdog that curls `/healthz` on a 30-second timer. The health endpoint returns 200 with `access_log off` so the constant probes do not flood the logs; the 200 itself is not the test, delivering it is, since a dead or hung nginx cannot. On a non-200 the watchdog SIGKILLs nginx rather than calling `systemctl restart`, so recovery routes through Layer 1 and is counted against StartLimit. A direct restart would bypass that accounting and the burst cap would never trip. An `is-failed` guard backs the watchdog off if nginx is already in failed state.

**Log rotation with safe rollover** \
Logrotate rotates nginx logs daily, retains 7, compresses with a one-cycle delay, and caps at 10M using `maxsize`. `maxsize` is deliberate: a bare `size` directive silently overrides the daily schedule, rotating only on size. A `postrotate` directive sends `USR1` to nginx after rotation so it reopens its descriptor and writes to the new file immediately. Verified with a `logrotate -d` dry run.

**Fail2ban present but inert by design** \
`jail.local` sets `maxretry 5`, `findtime 600`, `bantime 3600`, with `[sshd]` and `[nginx-http-auth]` enabled. With zero inbound there is nothing to ban, so both jails are inert on this host. They are baked into the golden AMI so the mechanism is present the moment an inbound surface exists at the ALB in Project 3: VPC Defense. This is a documented decision, not active protection. Fail2ban pulls in `firewalld` as a dependency, but `firewalld` comes up inactive and is irrelevant given zero inbound plus security-group-governed access, so no action is taken on it.

**CloudWatch session audit trail** \
Every SSM session is logged to `/ssm/sessions` off the instance with 7-day retention. An attacker with instance access cannot delete these logs. The inline IAM policy uses two statements: `logs:DescribeLogGroups` on a wildcard resource because it is a list operation that cannot be resource-scoped, and `logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogStreams` scoped to the log-group ARN with a `:*` suffix to cover the streams inside the group. At-rest KMS encryption on the log group is deferred for this dev environment; enforce-encryption is left off because Session Manager will not write without a CMK once it is on. Logged as an accepted gap.

**Docker runs rootless under a dedicated identity** \
`ssm-user` never touches Docker. Container operations run rootless under `dockerrl`, a dedicated non-interactive identity, so the interactive identity has no path to host root. Two walls stand here: rootless means the daemon and containers run unprivileged, so a container that escapes lands as a nobody rather than host root, and the dedicated identity means compromising the interactive session does not even reach the daemon. This phase is part-manual because of the user switch and the interactive rootless install, which is why the rebuild script splits into `setup.md` here. \
Several AL2023 realities are baked into the procedure so a rebuild does not rediscover them. Only `docker` and `systemd-container` are installed; `shadow-utils` is already present, and `slirp4netns` and `fuse-overlayfs` are absent from the base repo and unnecessary on this kernel, so listing them would fail the whole `dnf` transaction. AL2023's `docker` package does not ship `dockerd-rootless-setuptool.sh`, so rootless is installed via the `get.docker.com/rootless` script run as `dockerrl`. The install fails until the `nf_tables` kernel module is loaded, so it is loaded and persisted as `ssm-user` before entering the `dockerrl` session. Lingering is enabled first so the user systemd instance survives logout, and entry is through `machinectl` rather than `sudo su`, which fails with a bus error because it attaches no systemd user session.

**Golden AMI captured** \
The instance was captured as `golden-ami` after full verification, with the image and snapshot tagged together. Later builds launch from this image.

## How to Use

Follow the manual console checklist for the steps that cannot be scripted: the IAM role and the CloudWatch log group, Session Manager preferences, the inline policy, and the `dockerrl` rootless install. Then run `setup.md`'s scripted portions on a fresh instance launched from the golden AMI.

To tear down, run `nuke.sh`. It requires typing `NUKE` to confirm before touching anything. It terminates all tagged instances, waits for full termination, and releases tagged Elastic IPs, with every destructive action printed before it runs. The root volume dies on termination via DeleteOnTermination. The golden AMI, its snapshot, the security group, and the `/ssm/sessions` log group are left intact deliberately as reused infrastructure.

## Verification

**Kill test** \
`kill -9` on the nginx master PID. New PID within 5 seconds, confirming Layer 1 systemd restart.

**Degraded test** \
Forced `/healthz` to non-200 while the PID stayed alive. Recovered in about 30 seconds, and `journalctl` showed the watchdog kill routed through systemd, not a direct restart.

**Metadata test** \
Tokenless curl to IMDS returned 401, not 403. A 403 would indicate IMDS is off or blocked at the network layer, a different failure mode.

**Container IMDS test** \
As `dockerrl`, a container attempted the IMDS token request and returned 200, obtaining a token. This is a documented finding, not a pass. Docker 29's `gvisor-tap-vsock` rootless driver routes container traffic to IMDS within the hop budget, so hop limit 1 does not block it. The real fix, a `DOCKER-USER` iptables rule dropping container traffic to `169.254.169.254`, is deferred to Project 3: VPC Defense. Rootless isolation and IMDSv2 enforcement themselves remain intact.

**Audit test** \
Session commands appeared under `/ssm/sessions` within 60 seconds of session start, typos recorded, proving keystroke-level capture.

**Clean-slate test** \
After nuke and AMI capture, a fresh instance launched from `golden-ami` plus `setup.md` brought the full stack up with no manual steps beyond the console prerequisites and the `dockerrl` checklist.

## Known Gaps

No WAF or CloudFront sits in front of nginx. HTTP reaches the instance directly with no layer 7 filtering. Addressed in Project 2: Edge Hardening.

The instance runs in the default VPC with a public subnet and allow-all egress. Private subnet architecture with VPC Endpoints for internal-only service traffic is built in Project 3: VPC Defense.

Hop limit 1 does not block rootless containers from reaching IMDS on Docker 29, because the `gvisor-tap-vsock` driver routes within the hop budget. The network-level fix, a `DOCKER-USER` iptables rule, is deferred to Project 3: VPC Defense.

At-rest KMS encryption on the session log group is deferred for dev. Production would enforce a customer-managed key and longer retention depending on the applicable framework.

Fail2ban is inert on this build by design and becomes active with the Project 3: VPC Defense ALB.
