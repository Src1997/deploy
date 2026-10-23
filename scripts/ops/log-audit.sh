#!/bin/bash
# 日志/磁盘审计：防内存与硬盘爆
echo "===== 磁盘 ====="
df -h / | tail -1
echo "===== 日志大头（>100MB 的目录/文件）====="
du -sh /var/log /www/wwwlogs /var/log/journal /var/lib/docker 2>/dev/null | awk '$1 ~ /[GM]/ {print}'
find /var/log /www/wwwlogs -type f -size +100M 2>/dev/null | head -5
echo "===== journald ====="
journalctl --disk-usage 2>/dev/null | tail -1
grep -E '^SystemMaxUse|^#SystemMaxUse' /etc/systemd/journald.conf 2>/dev/null || echo "SystemMaxUse 未设置（默认上限 10% 磁盘，可到 4GB+）"
echo "===== logrotate 覆盖 ====="
ls /etc/logrotate.d/ 2>/dev/null | head -10
grep -l 'wwwlogs\|nginx' /etc/logrotate.d/* 2>/dev/null | head -3 || echo "⚠️ wwwlogs/nginx 无 logrotate"
echo "===== supervisor stdout 轮转 ====="
grep -E 'stdout_logfile_maxbytes|stdout_logfile_backups' /www/server/panel/plugin/supervisor/profile/financial-*.ini 2>/dev/null | head -4 || grep -E 'stdout_logfile_maxbytes|stdout_logfile_backups' /etc/supervisor*/conf.d/financial* 2>/dev/null | head -4
echo "===== 应用 logs/ ====="
du -sh /www/wwwroot/project/financial/financial-api/package/logs 2>/dev/null
ls -la /www/wwwroot/project/financial/financial-api/package/logs/ 2>/dev/null | awk '{print $5, $9}' | tail -5
echo "===== docker（如有）====="
command -v docker >/dev/null 2>&1 && docker ps -q 2>/dev/null | wc -l || echo "无 docker"
echo "===== OOM 历史 ====="
dmesg 2>/dev/null | grep -ci "out of memory" || journalctl -k 2>/dev/null | grep -ci "out of memory" || echo 0
echo "===== 内存 ====="
free -m | head -2
