#!/bin/bash
# 日志防爆炸修补：journald 限容 + wwwlogs logrotate
set -e
echo "== 1. journald SystemMaxUse=200M =="
if ! grep -qE '^SystemMaxUse=200M' /etc/systemd/journald.conf 2>/dev/null; then
  sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=200M/' /etc/systemd/journald.conf
  grep -q '^SystemMaxUse=200M' /etc/systemd/journald.conf || echo 'SystemMaxUse=200M' >> /etc/systemd/journald.conf
fi
grep '^SystemMaxUse' /etc/systemd/journald.conf
systemctl restart systemd-journald
journalctl --disk-usage | tail -1

echo "== 2. wwwlogs logrotate（copytruncate 免 reload）=="
cat > /etc/logrotate.d/wwwlogs <<'EOF'
/www/wwwlogs/*.log {
    daily
    rotate 7
    maxsize 50M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    dateext
}
EOF
logrotate -d /etc/logrotate.d/wwwlogs 2>&1 | tail -2
echo "== done =="
