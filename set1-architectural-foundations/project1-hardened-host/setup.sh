#!/bin/bash

set -e

# Golden AMI ID: ami-084672faad54ae817
# MANUAL CHECKLIST (console steps that cannot be scripted)
# 1. Create IAM Role with AmazonSSMManagedInstanceCore
# 2. Add inline CloudWatch policy to the role (see below)
# 3. Launch t3.micro on Amazon Linux 2023
#    - Tag: Project: Cloud-Security, Env: Dev
#    - Attach IAM role as instance profile
#    - Security group with zero inbound rules
#    - IMDSv2 required, hop limit 1
#    - No key pair
# 4. Create CloudWatch log group /ssm/sessions (1 week retention)
#    - Tag: Project: Cloud-Security
# 5. Enable CloudWatch logging in Session Manager preferences
#    - Point at /ssm/sessions
#    - Do not enforce encryption

# CLOUDWATCH IAM INLINE POLICY
#
# {
#     "Version": "2012-10-17",
#     "Statement": [
#         {
#             "Effect": "Allow",
#             "Action": "logs:DescribeLogGroups",
#             "Resource": "*"
#         },
#         {
#             "Effect": "Allow",
#             "Action": [
#                 "logs:CreateLogStream",
#                 "logs:PutLogEvents",
#                 "logs:DescribeLogStreams"
#             ],
#             "Resource": "arn:aws:logs:*:*:log-group:/ssm/sessions:*"
#         }
#     ]
# }


# phase 3: nginx
sudo dnf update -y && sudo dnf install -y nginx
sudo systemctl enable --now nginx
sudo mkdir -p /etc/systemd/system/nginx.service.d
sudo tee /etc/systemd/system/nginx.service.d/override.conf <<'EOF'
[Service]
Restart=always
RestartSec=5s
EOF
sudo systemctl daemon-reload

# phase 4: logrotate
sudo tee /etc/logrotate.d/nginx <<'EOF'
/var/log/nginx/*.log {
daily
rotate 7
compress
delaycompress
missingok
size 10M
postrotate
[ ! -f /run/nginx.pid ] || kill -USR1 $(cat /run/nginx.pid)
endscript
}
EOF

# phase 5: fail2ban
sudo dnf install -y fail2ban
sudo tee /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true

[nginx-http-auth]
enabled = true
EOF
sudo systemctl enable --now fail2ban

# phase 7: docker
sudo dnf install -y docker && sudo systemctl enable --now docker
sudo usermod -aG docker ssm-user