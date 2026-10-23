#!/usr/bin/env bash
# 部署符合性逐项核对（只读+探测，不改配置）
# 用法: BASE_DOMAIN=www.deepquant.club bash check-deploy.sh
D="${BASE_DOMAIN:?need BASE_DOMAIN}"
P=0; F=0
ok(){ echo "  [PASS] $1"; P=$((P+1)); }
bad(){ echo "  [FAIL] $1"; F=$((F+1)); }

echo "== 1 站点 conf 命名（html_ 前缀约定） =="
for s in deepquant-web.local financial-web.local financial-admin.local official-site.local; do
  [ -f /www/server/panel/vhost/nginx/html_$s.conf ] && ok "html_$s.conf" || bad "html_$s.conf 缺失"
  [ -f /www/server/panel/vhost/nginx/$s.conf ] && bad "无前缀 conf 残留: $s.conf" || true
  [ -f /www/server/panel/vhost/rewrite/html_$s.conf ] && ok "rewrite/html_$s.conf" || bad "rewrite/html_$s.conf 缺失"
done
if grep -lE 'vhost/rewrite/[a-z-]+\.local\.conf' /www/server/panel/vhost/nginx/html_*.conf 2>/dev/null | grep -q .; then
  bad "存在未同步为 html_ 前缀的 rewrite include"
else ok "rewrite include 全部已同步"; fi

echo "== 2 nginx 配置与运行 =="
nginx -t >/dev/null 2>&1 && ok "nginx -t 通过" || bad "nginx -t 失败"
# server_name 查重：按 listen 端口分组（同组重复才算冲突；80/443 同名是标准设计）
SDUP=$(/www/server/panel/pyenv/bin/python3 -c "
import re, subprocess
t = subprocess.run(['nginx','-T'], capture_output=True, text=True).stdout
pairs = []
for b in re.findall(r'server\s*\{([^{}]*)', t):
    lp = re.search(r'listen\s+[\d.:\[\]]*?(\d+)\b', b)
    sn = re.search(r'server_name\s+([^;]+);', b)
    if lp and sn: pairs.append((lp.group(1), sn.group(1).strip()))
dups = [p for p in set(pairs) if pairs.count(p) > 1]
print(len(dups))" 2>/dev/null)
[ "$SDUP" = "0" ] && ok "server_name 无同端口重复冲突" || bad "server_name 同端口重复数=$SDUP"

echo "== 3 面板功能读取（流量限制/网站日志/SSL） =="
cat > /tmp/chk_panel.py << 'EOF'
import sys
sys.path.insert(0, '/www/server/panel'); sys.path.insert(0, '/www/server/panel/class')
class G(dict):
    def __getattr__(self, k): return self[k]
    def __setattr__(self, k, v): self[k] = v
from logsModel.siteModel import main as SL
from projectModel.htmlModel import main as HM
from panelSite import panelSite as PS
sl, hm, ps = SL(), HM(), PS()
ids = {r[0]: r[1] for r in __import__('sqlite3').connect('/www/server/panel/data/db/site.db').execute('select id,name from sites where project_type="html"')}
fails = 0
for sid, name in ids.items():
    if not sl.get_site_log_file(G(siteName=name)).get('status'): print('LOGFAIL', name); fails += 1
    if 'perserver' not in hm.get_limit_net(G(site_id=sid)): print('LIMITFAIL', name); fails += 1
    if not isinstance(ps.GetSSL(G(siteName=name)), dict): print('SSLFAIL', name); fails += 1
print('PANEL_FAILS=%d' % fails)
EOF
PF=$(/www/server/panel/pyenv/bin/python3 /tmp/chk_panel.py 2>/dev/null | grep -oP 'PANEL_FAILS=\K\d+')
[ "$PF" = "0" ] && ok "4 站点 日志/流量限制/SSL 面板读取全部正常" || bad "面板功能读取异常数=$PF"
rm -f /tmp/chk_panel.py

echo "== 4 站点访问（带斜杠 200 + 无斜杠 301） =="
for p in "/" "/admin/" "/qd/" "/quant/"; do
  c=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "https://$D$p"); [ "$c" = "200" ] && ok "$p → 200" || bad "$p → $c"
done
for p in "/admin" "/qd" "/quant"; do
  c=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "https://$D$p"); [ "$c" = "301" ] && ok "$p → 301" || bad "$p → $c"
done

echo "== 5 MCP（streamable-http） =="
c=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 -X POST "https://$D/mcp" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"1"}},"id":1}')
[ "$c" = "200" ] && ok "/mcp initialize → 200" || bad "/mcp → $c"
grep -q 'QUANTDINGER_MCP_TRANSPORT=streamable-http' /www/server/panel/plugin/supervisor/profile/quantdinger-mcp.ini && ok "MCP transport=streamable-http" || bad "MCP transport 配置异常"

echo "== 6 端口绑定与进程归属 =="
ss -tln | grep -q '127.0.0.1:5000' && ! ss -tln | grep -q '0.0.0.0:5000' && ok "5000 仅绑 127.0.0.1" || bad "5000 绑定异常"
ss -tln | grep -q '127.0.0.1:5001' && ! ss -tln | grep -q '0.0.0.0:5001' && ok "5001 仅绑 127.0.0.1" || bad "5001 绑定异常"
ss -tln | grep -q '127.0.0.1:7800' && ok "7800 仅绑 127.0.0.1" || bad "7800 绑定异常"

echo "== 7 服务守护归属（宝塔单轨） =="
SC=/www/server/panel/pyenv/bin/supervisorctl
[ -x $SC ] && for s in financial-crawler financial-worker financial-streaming quantdinger-mcp; do
  $SC status 2>/dev/null | grep "^$s" | grep -q RUNNING && ok "supervisor: $s RUNNING" || bad "supervisor: $s 未 RUNNING"
done
PYPROJ=$(/www/server/panel/pyenv/bin/python3 -c "
import sys; sys.path.insert(0,'/www/server/panel'); sys.path.insert(0,'/www/server/panel/class')
import json
from mod.project.python.projectMod import main
" 2>/dev/null; echo n/a)
systemctl list-unit-files 2>/dev/null | grep -E 'financial|quantdinger|deepquant' | grep -q enabled && bad "存在 enabled 的旧 systemd 单元" || ok "无 systemd 双轨残留"
[ -d /etc/systemd/system/quantdinger-backend.service.d ] && bad "quantdinger-backend.service.d 残留" || ok "无 .service.d 残留"

echo "== 8 crontab =="
crontab -l 2>/dev/null | grep -q 'quant-dinger/quantdinger-api' && bad "@reboot 旧 quantdinger cron 残留" || ok "无旧 quantdinger 启动 cron"
crontab -l 2>/dev/null | grep -q 'acme.sh' && ok "acme.sh 续签 cron 在位" || bad "acme.sh cron 缺失"

echo "== 9 Redis/WG =="
# 生效配置是宝塔的 /www/server/redis/redis.conf（/etc/redis 是系统包残留）；无 Redis 则视为正常
if [ -f /www/server/redis/redis.conf ]; then
  BIND=$(grep -oP '^bind \K.*' /www/server/redis/redis.conf | head -1)
  case "$BIND" in
    *0.0.0.0*) bad "Redis bind 含 0.0.0.0: $BIND" ;;
    *10.10.0.2*) ok "Redis bind=[$BIND]（含 WG 地址）" ;;
    *127.0.0.1*) ok "Redis bind=[$BIND]（仅本机）" ;;
    *) bad "Redis bind 异常: $BIND" ;;
  esac
else ok "本机无宝塔 Redis（正常，Redis 在远端）"; fi
wg show wg0 2>/dev/null | grep -q 'latest handshake' && ok "WireGuard 隧道有握手" || bad "WireGuard 无握手"

echo "== 10 权限与残留 =="
[ "$(stat -c %a /www/wwwroot/project/deploy.env.server-* 2>/dev/null | sort -u | tr -d '\n')" = "600" ] && ok "deploy.env 600" || bad "deploy.env 权限非 600"
find /www/wwwroot/project -maxdepth 3 -type d -perm 777 2>/dev/null | grep -q . && bad "仍存在 777 目录" || ok "无 777 目录"
find /www/server/panel/vhost -name '*.bak*' 2>/dev/null | grep -q . && bad "vhost 存在 .bak 残留" || ok "vhost 目录干净"
[ -d /www/wwwroot/project/official-website ] && bad "official-website 空目录残留" || ok "无 official-website 残留"

echo "== 11 备份在位 =="
ls /root/vhost-backup-20261023.tar.gz /root/systemd-backup-20261023 >/dev/null 2>&1 && ok "vhost/systemd 备份在位" || bad "备份缺失（检查 /root/*backup*）"

echo "== 12 面板站点注册与域名 =="
N=$(python3 -c "
import sqlite3
c=sqlite3.connect('/www/server/panel/data/db/site.db')
print(c.execute('select count(*) from sites').fetchone()[0])" 2>/dev/null)
[ "$N" = "6" ] && ok "面板注册站点 6 个（4 html + 2 Python）" || bad "面板站点数=$N（预期 6）"

echo ""
echo "===== 结果: PASS=$P FAIL=$F ====="
