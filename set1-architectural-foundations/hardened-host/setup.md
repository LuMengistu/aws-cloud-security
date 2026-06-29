# Hardened Host Setup

Golden AMI: `ami-05e4c95d4bf1a0bfa` (`golden-ami`, us-west-2)

This rebuilds the hardened host. It splits into two parts because it cannot run as a single script: the rootless Docker section switches to a non-interactive user (`dockerrl`) with its own systemd session, which breaks linear execution. Part 1 is a runnable block. Part 2 is a manual checklist run as `dockerrl`.

## Console Prerequisites

**Launch**
- IAM role with `AmazonSSMManagedInstanceCore`, tagged `Project: Cloud-Security`, `Env: Dev`.
- t3.micro on Amazon Linux 2023, tagged at creation. No key pair.
- Security group with zero inbound rules. Default allow-all egress left in place.
- IMDSv2 required, hop limit 1.

**CloudWatch**
- Log group /ssm/sessions, 7-day retention, tagged Project: Cloud-Security, Env: Dev
- Session Manager preferences: enable CloudWatch logging, point at `/ssm/sessions`, enforce-encryption off.
- Inline IAM policy on the role: `logs:DescribeLogGroups` on `*`; `logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogStreams` on `arn:aws:logs:*:*:log-group:/ssm/sessions:*`.

## Part 1 — Scriptable Block

Connect via SSM Session Manager and run this block.

```bash
#!/bin/bash
set -eo pipefail

# system update, install nginx, enable nginx
sudo dnf update -y
sudo dnf install nginx -y
sudo systemctl enable --now nginx

# layer 1: systemd restart with crash-loop cap
sudo mkdir -p /etc/systemd/system/nginx.service.d
sudo tee /etc/systemd/system/nginx.service.d/override.conf <<'EOF'
[Unit]
StartLimitIntervalSec=60
StartLimitBurst=3
[Service]
Restart=on-failure
RestartSec=5s
EOF
sudo systemctl daemon-reload

# health check endpoint (the probe target Layer 2 uses)
sudo tee /etc/nginx/default.d/healthz.conf <<'EOF'
location = /healthz {
  access_log off;
  return 200;
}
EOF
sudo nginx -t && sudo systemctl reload nginx

# layer 2: health watchdog (kills nginx so Layer 1's counted restart recovers it)
sudo tee /usr/local/bin/nginx-watchdog.sh <<'EOF'
#!/bin/bash
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1/healthz)
if [ "$HTTP_CODE" != "200" ]; then
  logger -t nginx-watchdog "Health check failed (HTTP $HTTP_CODE)."
  if systemctl is-failed --quiet nginx; then
    logger -t nginx-watchdog "nginx already failed, leaving for investigation."
    exit 0
  fi
  logger -t nginx-watchdog "Signaling nginx for systemd-managed restart."
  systemctl kill --signal=SIGKILL nginx
fi
EOF
sudo chmod +x /usr/local/bin/nginx-watchdog.sh

sudo tee /etc/systemd/system/nginx-watchdog.service <<'EOF'
[Unit]
Description=Nginx health watchdog
After=nginx.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/nginx-watchdog.sh
EOF

sudo tee /etc/systemd/system/nginx-watchdog.timer <<'EOF'
[Unit]
Description=Run nginx health watchdog every 30 seconds
Requires=nginx-watchdog.service
[Timer]
OnActiveSec=30
OnUnitActiveSec=30
AccuracySec=1s
[Install]
WantedBy=timers.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now nginx-watchdog.timer

# log rotation
sudo tee /etc/logrotate.d/nginx <<'EOF'
/var/log/nginx/*.log {
  daily
  rotate 7
  maxsize 10M
  compress
  delaycompress
  missingok
  postrotate
    [ ! -f /run/nginx.pid ] || kill -USR1 $(cat /run/nginx.pid)
  endscript
}
EOF

# fail2ban (inert on zero-inbound, baked for downstream ALB)
sudo dnf install fail2ban -y
sudo tee /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
maxretry = 5
findtime = 600
bantime = 3600
[sshd]
enabled = true
[nginx-http-auth]
enabled = true
EOF
sudo systemctl enable --now fail2ban
```

## Part 2 — Rootless Docker (manual checklist, run as dockerrl)

Cannot be scripted in one flow because entering `dockerrl` opens an interactive session. Run in order.

AL2023 realities: install only `docker` and `systemd-container` (`shadow-utils` already present; `slirp4netns` and `fuse-overlayfs` not in the base repo and not needed on this kernel). AL2023's `docker` package does not ship the rootless setup tool, so it is installed via the official curl script. The rootless install fails until `nf_tables` is loaded.

Run as `ssm-user`:

```bash
# create the dedicated docker user
sudo useradd -m -s /bin/bash dockerrl

# install docker + systemd-container only
sudo dnf install -y docker systemd-container

# subuid/subgid range (AL2023 auto-assigns; guard makes this a safe no-op or insurance)
grep -q '^dockerrl:' /etc/subuid || sudo usermod --add-subuids 100000-160000 --add-subgids 100000-160000 dockerrl

# disable the rootful daemon so rootless owns container ops
sudo systemctl disable --now docker.service docker.socket

# load nf_tables now and persist it across reboots (rootless networking needs it)
sudo modprobe nf_tables
echo nf_tables | sudo tee /etc/modules-load.d/nf_tables.conf

# enable lingering so dockerrl's user services survive logout
sudo loginctl enable-linger dockerrl
```

Enter `dockerrl` with a real systemd session (not `sudo su`, which fails with a bus error):

```bash
sudo machinectl shell dockerrl@
```

Now as `dockerrl`:

```bash
# install rootless docker (AL2023 lacks the bundled setuptool)
curl -fsSL https://get.docker.com/rootless | sh

# set env vars so the docker client finds the binary and the rootless socket
# note: 1002 is dockerrl's UID; confirm with `id -u` if it differs on rebuild
echo 'export PATH=/home/dockerrl/bin:$PATH' >> ~/.bashrc
echo 'export DOCKER_HOST=unix:///run/user/1002/docker.sock' >> ~/.bashrc
source ~/.bashrc
```

Verify rootless:

```bash
docker info | grep -i rootless
ps -u dockerrl -o user,pid,comm | grep -E 'dockerd|rootlesskit'
```

Expect `rootless` in the `docker info` output, and `dockerd` + `rootlesskit` owned by `dockerrl`, not root.

## After the Build

Run the verification checks (see the directive). Capture the golden AMI from the verified instance only after verification passes. Run `nuke.sh` to tear down.
