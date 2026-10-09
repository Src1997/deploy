#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# 06-fix-ssl-cert.sh — SSL 证书签发 / 自动续签（acme.sh + webroot 验证）
#
# 适用：服务器 A（zhuochouacedemy.com）/ 服务器 B（deepquant.club）
# 用法（在目标服务器上执行，按需覆盖变量）：
#   DOMAIN=deepquant.club \
#   EXTRA_DOMAINS="www.deepquant.club mail.deepquant.club" \
#   CERT_NAMES="www.deepquant.club mail.deepquant.club" \
#   bash 06-fix-ssl-cert.sh
#
# 做了什么：
#   1. 备份现有证书到 /www/backup/cert-<日期>
#   2. 建 webroot 目录 /www/wwwroot/project/acme
#   3. nginx 80 端口块插入 /.well-known/acme-challenge/ 验证路径（幂等）
#   4. 安装 acme.sh（幂等），用 Let's Encrypt 签发证书
#   5. 生成通用续签同步脚本 /root/scripts/bt-cert-sync.sh（幂等重写）
#   6. 安装证书到宝塔证书目录（多个目录同步同一张证书）
#   7. reload nginx + 同步面板/邮局副本
#   8. acme.sh 自带每日续签 cron（到期前自动续，续签后经 reloadcmd
#      自动同步三处副本：nginx 网站 / 宝塔面板 / 宝塔邮局）
#
# ★背景（2026-10-09 事故）：acme.sh 只续证书本身；宝塔面板与邮局各持有
#   一份独立证书副本，此前 reloadcmd 只 reload nginx，导致面板证书过期
#   "进不去"、邮局证书报红。本版起 reloadcmd 指向 bt-cert-sync.sh 一次同步三处。
#   服务器 B 上 2026-10-09 手工部署的 /root/scripts/sync-deepquant-cert.sh
#   已被本逻辑取代（重跑本脚本会改写 reloadcmd 指向 bt-cert-sync.sh，旧脚本可删）。
#
# 幂等：重复执行安全。已配置则跳过配置，仅续签/重装证书。
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

# ── 可配置变量（默认值按服务器 B 填写；服务器 A 请覆盖）──
DOMAIN="${DOMAIN:-deepquant.club}"
EXTRA_DOMAINS="${EXTRA_DOMAINS:-www.deepquant.club mail.deepquant.club}"
# 宝塔证书目录名（空格分隔）；第一个为主目录，其余为同步副本
CERT_NAMES="${CERT_NAMES:-www.deepquant.club mail.deepquant.club}"
ACME_WEBROOT="${ACME_WEBROOT:-/www/wwwroot/project/acme}"
EMAIL="${EMAIL:-admin@${DOMAIN}}"
NGINX_CONF="${NGINX_CONF:-/www/server/panel/vhost/nginx/default.conf}"
CERT_BASE="${CERT_BASE:-/www/server/panel/vhost/cert}"
ACME_HOME="${ACME_HOME:-/root/.acme.sh}"
ACME_BIN="${ACME_BIN:-${ACME_HOME}/acme.sh}"

log()  { printf '\033[36m[SSL]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[警告]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[失败]\033[0m %s\n' "$*" >&2; exit 1; }

command -v nginx  >/dev/null || die "未找到 nginx"
command -v python3 >/dev/null || die "未找到 python3"

# ── 1. 备份现有证书 ─────────────────────────────────────────
BACKUP_DIR="/www/backup/cert-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${BACKUP_DIR}"
for name in ${CERT_NAMES}; do
  if [ -d "${CERT_BASE}/${name}" ]; then
    cp -a "${CERT_BASE}/${name}" "${BACKUP_DIR}/" 2>/dev/null || true
  fi
done
log "已备份现有证书到 ${BACKUP_DIR}"

# ── 2. 建 webroot 目录 ──────────────────────────────────────
mkdir -p "${ACME_WEBROOT}/.well-known/acme-challenge"
chmod 755 "${ACME_WEBROOT}"
log "webroot 就绪：${ACME_WEBROOT}"

# ── 3. nginx 插入 ACME 验证路径（幂等）────────────────────
if grep -q 'acme-challenge' "${NGINX_CONF}" 2>/dev/null; then
  log "nginx 已配置 acme-challenge，跳过"
else
  cp -a "${NGINX_CONF}" "${NGINX_CONF}.bak-$(date +%Y%m%d-%H%M%S)"
  python3 - "${NGINX_CONF}" "${ACME_WEBROOT}" <<'PYEOF'
import sys, re
conf_path, webroot = sys.argv[1], sys.argv[2]
lines = open(conf_path, encoding='utf-8').read().split('\n')

# 定位 80 端口 server 块：找含 "listen 80;" 的行，回退到最近的 "server {" 行
start = None
for i, ln in enumerate(lines):
    if re.search(r'listen\s+80\s*;', ln):
        for j in range(i, -1, -1):
            if re.search(r'\bserver\s*\{', lines[j]):
                start = j
                break
        break
if start is None:
    sys.exit("未找到 listen 80 的 server 块")

# 在该块内第一个 location 之前插入
ins = None
for k in range(start, len(lines)):
    if re.match(r'\s*location\b', lines[k]):
        ins = k
        break
    if k > start and re.match(r'\s*server\s*\{', lines[k]):
        break
if ins is None:
    sys.exit("未找到插入点")

block = [
    '    # -- ACME 验证路径（SSL 自动续签用，勿删）--',
    '    location ^~ /.well-known/acme-challenge/ {',
    '        root %s;' % webroot,
    '        default_type "text/plain";',
    '    }',
    '',
]
lines[ins:ins] = block
open(conf_path, 'w', encoding='utf-8').write('\n'.join(lines))
print("已在第 %d 行前插入 acme-challenge" % (ins + 1))
PYEOF
  nginx -t 2>&1 | tail -2
  systemctl reload nginx
  log "nginx 配置已更新并 reload"
fi

# 验证 HTTP-01 验证路径可达（自建探测文件）
echo "acme-probe-$(date +%s)" > "${ACME_WEBROOT}/.well-known/acme-challenge/probe.txt"
PROBE_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  "http://${DOMAIN}/.well-known/acme-challenge/probe.txt" || echo "000")
if [ "${PROBE_CODE}" = "200" ]; then
  log "验证路径可达（HTTP ${PROBE_CODE}），具备签发条件"
else
  warn "验证路径返回 ${PROBE_CODE}；若非 200 签发会失败，请检查 80 端口与安全组"
fi
rm -f "${ACME_WEBROOT}/.well-known/acme-challenge/probe.txt"

# ── 4. 安装 acme.sh（幂等）──────────────────────────────────
if [ ! -f "${ACME_BIN}" ]; then
  log "安装 acme.sh ..."
  curl -sS --max-time 60 https://get.acme.sh | sh -s email="${EMAIL}" >/dev/null 2>&1 \
    || die "acme.sh 安装失败"
fi
[ -f "${ACME_BIN}" ] || die "未找到 ${ACME_BIN}"
log "acme.sh 就绪：${ACME_BIN}"

# ── 5. 签发证书 ────────────────────────────────────────────
DOMAIN_ARGS=(-d "${DOMAIN}")
for d in ${EXTRA_DOMAINS}; do DOMAIN_ARGS+=(-d "${d}"); done

log "签发证书：${DOMAIN} ${EXTRA_DOMAINS}"
"${ACME_BIN}" --issue "${DOMAIN_ARGS[@]}" -w "${ACME_WEBROOT}" \
  --server letsencrypt --accountemail "${EMAIL}" --force 2>&1 | tail -15 \
  || die "证书签发失败（检查域名解析是否指向本机、80 端口是否放行）"

# ── 6a. 生成续签同步脚本（网站/面板/邮局三处副本，幂等重写）──
SYNC_SCRIPT="/root/scripts/bt-cert-sync.sh"
mkdir -p /root/scripts
cat > "${SYNC_SCRIPT}" <<'SYNC_EOF'
#!/bin/bash
# 由 deploy/scripts/ops/06-fix-ssl-cert.sh 生成（每次运行该脚本时幂等重写）
# acme.sh 续签成功后经 --reloadcmd 调用：同步证书到三处副本并重启对应服务
# 用法: bt-cert-sync.sh <主域名>
DOMAIN="$1"
LOG=/var/log/cert-sync.log
SRC="/root/.acme.sh/${DOMAIN}_ecc"
[ -d "$SRC" ] || SRC="/root/.acme.sh/${DOMAIN}"
echo "[$(date '+%F %T')] cert sync start (${DOMAIN})" >> "$LOG"

# 1) nginx 网站（acme.sh 已直接安装到 vhost/cert，此处 reload）
nginx -t >> "$LOG" 2>&1 && systemctl reload nginx \
  && echo "[$(date '+%F %T')] nginx reloaded" >> "$LOG"

# 2) 宝塔面板（装了宝塔才同步；面板证书在启动时加载，需 restart）
if [ -d /www/server/panel/ssl ]; then
  cp -f "$SRC/fullchain.cer" /www/server/panel/ssl/certificate.pem
  cp -f "$SRC/${DOMAIN}.key" /www/server/panel/ssl/privateKey.pem
  chmod 600 /www/server/panel/ssl/certificate.pem /www/server/panel/ssl/privateKey.pem
  /etc/init.d/bt restart > /dev/null 2>&1 \
    && echo "[$(date '+%F %T')] panel restarted" >> "$LOG"
fi

# 3) 宝塔邮局（装了邮局插件才同步；dovecot/postfix TLS 用）
MAIL_CERT_DIR="/www/server/panel/plugin/mail_sys/cert/${DOMAIN}"
if [ -d "$MAIL_CERT_DIR" ]; then
  cp -f "$SRC/fullchain.cer" "$MAIL_CERT_DIR/fullchain.pem"
  cp -f "$SRC/${DOMAIN}.key" "$MAIL_CERT_DIR/privkey.pem"
  chmod 600 "$MAIL_CERT_DIR"/fullchain.pem "$MAIL_CERT_DIR"/privkey.pem
  systemctl restart dovecot postfix \
    && echo "[$(date '+%F %T')] dovecot+postfix restarted" >> "$LOG"
fi

echo "[$(date '+%F %T')] cert sync done" >> "$LOG"
SYNC_EOF
chmod +x "${SYNC_SCRIPT}"
bash -n "${SYNC_SCRIPT}" || die "同步脚本语法错误"
log "续签同步脚本就绪：${SYNC_SCRIPT}（覆盖 网站/面板/邮局 三处）"

# ── 6b. 安装证书到宝塔目录 ──────────────────────────────────
PRIMARY_NAME=$(echo "${CERT_NAMES}" | awk '{print $1}')
PRIMARY_DIR="${CERT_BASE}/${PRIMARY_NAME}"
mkdir -p "${PRIMARY_DIR}"

log "安装证书到 ${PRIMARY_DIR}"
"${ACME_BIN}" --install-cert -d "${DOMAIN}" \
  --cert-file      "${PRIMARY_DIR}/cert.pem" \
  --key-file       "${PRIMARY_DIR}/privkey.pem" \
  --fullchain-file "${PRIMARY_DIR}/fullchain.pem" \
  --reloadcmd      "bash ${SYNC_SCRIPT} ${DOMAIN}" 2>&1 | tail -8

# 同步副本目录（如 mail.deepquant.club）
for name in ${CERT_NAMES}; do
  [ "${name}" = "${PRIMARY_NAME}" ] && continue
  D="${CERT_BASE}/${name}"
  mkdir -p "${D}"
  cp -f "${PRIMARY_DIR}/fullchain.pem" "${D}/fullchain.pem"
  cp -f "${PRIMARY_DIR}/privkey.pem"   "${D}/privkey.pem"
  [ -f "${PRIMARY_DIR}/cert.pem" ] && cp -f "${PRIMARY_DIR}/cert.pem" "${D}/cert.pem"
  chmod 600 "${D}"/*.pem
  log "已同步证书副本到 ${D}"
done
chmod 600 "${PRIMARY_DIR}"/*.pem

# ── 7. reload 并验证 ───────────────────────────────────────
systemctl reload nginx || nginx -s reload || true
sleep 2

log "── 验证结果 ──"
for name in ${CERT_NAMES}; do
  F="${CERT_BASE}/${name}/fullchain.pem"
  [ -f "${F}" ] && printf '  %-24s %s\n' "${name}" "$(openssl x509 -in "${F}" -noout -enddate 2>/dev/null)"
done
[ -f /www/server/panel/ssl/certificate.pem ] \
  && printf '  %-24s %s\n' "宝塔面板" "$(openssl x509 -in /www/server/panel/ssl/certificate.pem -noout -enddate 2>/dev/null)"
MAIL_CERT="/www/server/panel/plugin/mail_sys/cert/${DOMAIN}/fullchain.pem"
[ -f "${MAIL_CERT}" ] \
  && printf '  %-24s %s\n' "宝塔邮局" "$(openssl x509 -in "${MAIL_CERT}" -noout -enddate 2>/dev/null)"
echo
echo "远程校验（${DOMAIN}:443）："
echo | timeout 15 openssl s_client -connect "${DOMAIN}:443" -servername "${DOMAIN}" 2>/dev/null \
  | openssl x509 -noout -subject -dates 2>/dev/null | sed 's/^/  /'

# ── 8. 自动续签 ────────────────────────────────────────────
if crontab -l 2>/dev/null | grep -q 'acme.sh'; then
  log "自动续签任务已存在："
  crontab -l 2>/dev/null | grep 'acme.sh' | sed 's/^/  /'
else
  log "未检测到续签任务，acme.sh 安装时通常已自动写入，请手动确认"
fi

log "完成。证书有效期 90 天，acme.sh 每日检查、到期前自动续签；续签后经 reloadcmd 自动同步 网站/面板/邮局 三处副本（日志 /var/log/cert-sync.log）。"
