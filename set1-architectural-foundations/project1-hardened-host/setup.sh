#!/bin/bash

set -eo pipefail

# GOLDEN AMI: ami-09118f7090eec8c03

# Manual Checklist (console steps that are not scripted)
# 1. Create IAM role with AmazonSSMMangedInstanceCore
#     - Tag: Project: Cloud-Security, Env: Dev
# 2. Launch instance project1-instance
#     - Tag: Project: Cloud-Security, Env: Dev
#     - Amazon Linux 2023 AMI
#     - t3.micro instance type
#     - Proceed with no key pair
#     - Create project1-security-group with zero inbound rules
#     - Attach project1-role IAM role to instance
#     - IMDSv2 only + Hop limit 1
# 3. Create ssm/sessions/ log group in CloudWatch console
#     - 7 day retention
#     - Tag: Project: Cloud-Security, Env: Dev
# 4. Enable CloudWatch logging in Session Manager preferences
#    - Point at /ssm/sessions log group
#    - Do not enforce encryption
# 5. CloudWatch IAM inline policy
#	 {
#	 	 "Version": "2012-10-17",
#		 "Statement": [
#			 {
#				 "Effect": "Allow",
#				 "Action": "logs:DescribeLogGroups",
#				 "Resource": "*"
#			 },
#			 {
#				 "Effect": "Allow",
#				 "Action": [
#					 "logs:CreateLogStream",
#					 "logs:PutLogEvents",
#					 "logs:DescribeLogStreams"
#				 ],
#				 "Resource": "arn:aws:logs:*:*:log-group:/ssm/sessions:*"
#			 }
#		 ]
#	 }

# nginx setup & self-healing
sudo dnf update -y && sudo dnf install nginx -y
sudo systemctl enable --now nginx
sudo mkdir -p /etc/systemd/system/nginx.service.d
sudo tee /etc/systemd/system/nginx.service.d/override.conf <<'EOF'
[Unit]
StartLimitBurst=3
StartLimitIntervalSec=60

[Service]
Restart=on-failure
RestartSec=5s
EOF

sudo tee /usr/local/bin/nginx-watchdog.sh <<'EOF'
#!/bin/bash

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1/)
if [ "$HTTP_CODE" != "200" ]; then
	logger -t nginx-watchdog "Health check failed (HTTP $HTTP_CODE). Restarting nginx."
	systemctl restart nginx
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
OnActiveSec=30s
OnUnitActiveSec=30s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable --now nginx-watchdog.timer

# logrotate
sudo tee /etc/logrotate.d/nginx <<'EOF'
/var/log/nginx/*.log {
daily
rotate 7
size 10M
compress
delaycompress
missingok
postrotate
[ ! -f /run/nginx.pid ] || kill -USR1 $(cat /run/nginx.pid)
endscript
}
EOF

# fail2ban install and jail configurations
sudo dnf install fail2ban -y
sudo tee /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
maxretry=5
findtime=600
bantime=3600

[sshd]
enabled=true

[nginx-http-auth]
enabled=true
EOF

# docker install & ssm-user permissions
sudo dnf install docker -y
sudo systemctl enable --now docker
sudo usermod -aG docker ssm-user 



