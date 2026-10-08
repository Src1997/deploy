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
#   5. 安装证书到宝塔证书目录（多个目录同步同一张证书）
#   6. reload nginx
#   7. acme.sh 自带每日续签 cron（到期前自动续 + 自动 reload）
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

# ── 6. 安装证书到宝塔目录 ──────────────────────────────────
PRIMARY_NAME=$(echo "${CERT_NAMES}" | awk '{print $1}')
PRIMARY_DIR="${CERT_BASE}/${PRIMARY_NAME}"
mkdir -p "${PRIMARY_DIR}"

log "安装证书到 ${PRIMARY_DIR}"
"${ACME_BIN}" --install-cert -d "${DOMAIN}" \
  --cert-file      "${PRIMARY_DIR}/cert.pem" \
  --key-file       "${PRIMARY_DIR}/privkey.pem" \
  --fullchain-file "${PRIMARY_DIR}/fullchain.pem" \
  --reloadcmd      "nginx -t && systemctl reload nginx" 2>&1 | tail -8

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

log "完成。证书有效期 90 天，acme.sh 每日检查、到期前自动续签并 reload nginx。"
