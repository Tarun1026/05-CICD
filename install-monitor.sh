#!/usr/bin/env bash
set -Eeuo pipefail

# Run on EC2 as root after copying monitor-production.sh and rollback-app.sh to this host.
# Example:
#   SNS_TOPIC_ARN=arn:aws:sns:ap-southeast-2:123456789012:blue-green-alerts \
#   AWS_REGION=ap-southeast-2 bash install-monitor.sh

: "${SNS_TOPIC_ARN:?Set SNS_TOPIC_ARN to your SNS topic ARN}"
: "${AWS_REGION:?Set AWS_REGION, e.g. ap-southeast-2}"

install -m 0750 scripts/monitor-production.sh /usr/local/sbin/monitor-production.sh
install -m 0750 scripts/rollback-app.sh /usr/local/sbin/rollback-app.sh
mkdir -p /etc/blue-green
cat > /etc/blue-green/monitor.env <<EOF
AWS_REGION=${AWS_REGION}
SNS_TOPIC_ARN=${SNS_TOPIC_ARN}
INTERVAL_SECONDS=30
FAILURE_THRESHOLD=3
REPEAT_ALERT_SECONDS=600
EOF
chmod 600 /etc/blue-green/monitor.env

cat > /etc/systemd/system/blue-green-monitor.service <<'EOF'
[Unit]
Description=Blue-Green production health monitor and automatic rollback
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=root
EnvironmentFile=/etc/blue-green/monitor.env
ExecStart=/usr/local/sbin/monitor-production.sh
Restart=always
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now blue-green-monitor.service
systemctl --no-pager --full status blue-green-monitor.service
