#!/usr/bin/env bash
# setup-wireguard.sh — 单机侧 WireGuard 隧道配置（幂等）
#
# 在「每台」参与隧道的服务器上各跑一次。先生成对端公钥再配本机：
#   机器1: bash setup-wireguard.sh --name a --tunnel-ip 10.10.0.1/24 \
#            --peer-name b --peer-public-key <B公钥> \
#            --peer-tunnel-ip 10.10.0.2 --peer-endpoint 103.100.211.12:51820 \
#            --allow-ports 6379,5432
#   机器2: bash setup-wireguard.sh --name b --tunnel-ip 10.10.0.2/24 \
#            --peer-name a --peer-public-key <A公钥> \
#            --peer-tunnel-ip 10.10.0.1 --peer-endpoint 121.41.44.216:51820 \
#            --allow-ports 6379,5432
#
# 特性：
# - 幂等：已有密钥/配置不覆盖；重跑只补齐缺失项
# - 自动 apt 安装 wireguard、写 /etc/wireguard/wg0.conf、wg-quick up、enable 自启
# - ufw 放行：对端 endpoint 公网 IP → 监听端口（udp）；--allow-ports → wg0 接口
# - 私钥只落本机 /etc/wireguard/，禁止入库（公钥可记入 assets/wireguard/peers.md）
set -euo pipefail

IFACE="wg0"
CONF="/etc/wireguard/${IFACE}.conf"
KEY_DIR="/etc/wireguard"
LISTEN_PORT="51820"
TUNNEL_IP=""
NAME=""
PEER_NAME=""
PEER_PUBKEY=""
PEER_TUNNEL_IP=""
PEER_ENDPOINT=""
ALLOW_PORTS=""
DO_ENABLE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2;;
    --tunnel-ip) TUNNEL_IP="$2"; shift 2;;
    --listen-port) LISTEN_PORT="$2"; shift 2;;
    --peer-name) PEER_NAME="$2"; shift 2;;
    --peer-public-key) PEER_PUBKEY="$2"; shift 2;;
    --peer-tunnel-ip) PEER_TUNNEL_IP="$2"; shift 2;;
    --peer-endpoint) PEER_ENDPOINT="$2"; shift 2;;
    --allow-ports) ALLOW_PORTS="$2"; shift 2;;
    --no-enable) DO_ENABLE=0; shift;;
    *) echo "未知参数: $1" >&2; exit 1;;
  esac
done

for v in NAME TUNNEL_IP PEER_NAME PEER_PUBKEY PEER_TUNNEL_IP; do
  if [ -z "${!v}" ]; then echo "缺少必填参数 --${v,,}" >&2; exit 1; fi
done

log() { echo "[wg] $*"; }

# ── 1. 安装 ──────────────────────────────────────────────
if ! command -v wg >/dev/null 2>&1; then
  log "安装 wireguard..."
  apt-get update -qq && apt-get install -y -qq wireguard
fi

# ── 2. 密钥（幂等：已有不重生成）──────────────────────────
mkdir -p "$KEY_DIR"; chmod 700 "$KEY_DIR"
if [ ! -f "$KEY_DIR/${NAME}.key" ]; then
  wg genkey | tee "$KEY_DIR/${NAME}.key" | wg pubkey > "$KEY_DIR/${NAME}.pub"
  chmod 600 "$KEY_DIR/${NAME}.key"
  log "已生成密钥：$KEY_DIR/${NAME}.key（私钥禁入库）"
fi
PRIVATE_KEY="$(cat "$KEY_DIR/${NAME}.key")"
log "本机公钥（填入对端 --peer-public-key）：$(cat "$KEY_DIR/${NAME}.pub")"

# ── 3. 写配置 ────────────────────────────────────────────
if [ -f "$CONF" ]; then
  log "$CONF 已存在，跳过写入（幂等）。需重建请先 wg-quick down $IFACE && rm $CONF"
else
  {
    echo "[Interface]"
    echo "Address = $TUNNEL_IP"
    echo "ListenPort = $LISTEN_PORT"
    echo "PrivateKey = $PRIVATE_KEY"
    echo ""
    echo "[Peer]"
    echo "# $PEER_NAME"
    echo "PublicKey = $PEER_PUBKEY"
    echo "AllowedIPs = $PEER_TUNNEL_IP/32"
    [ -n "$PEER_ENDPOINT" ] && echo "Endpoint = $PEER_ENDPOINT"
    echo "PersistentKeepalive = 25"
  } > "$CONF"
  chmod 600 "$CONF"
  log "已写入 $CONF"
fi

# ── 4. 起隧道 + 自启 ─────────────────────────────────────
wg-quick up "$IFACE" 2>/dev/null || log "$IFACE 已在运行"
if [ "$DO_ENABLE" = "1" ]; then
  systemctl enable "wg-quick@${IFACE}" >/dev/null 2>&1 && log "开机自启已开"
fi

# ── 5. 防火墙 ────────────────────────────────────────────
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  # 对端 endpoint 公网 IP → 监听端口
  if [ -n "$PEER_ENDPOINT" ]; then
    PEER_PUB_IP="${PEER_ENDPOINT%%:*}"
    ufw allow from "$PEER_PUB_IP" to any port "$LISTEN_PORT" proto udp comment "WG-${NAME}" >/dev/null \
      && log "ufw: $PEER_PUB_IP → $LISTEN_PORT/udp 已放行"
  fi
  # 隧道接口内的业务端口（wg 进来的包同样过 INPUT 链，必须显式放行）
  if [ -n "$ALLOW_PORTS" ]; then
    ufw allow in on "$IFACE" to any port "$ALLOW_PORTS" proto tcp comment "WG-LAN-${NAME}" >/dev/null \
      && log "ufw: $IFACE → $ALLOW_PORTS/tcp 已放行"
  fi
else
  log "ufw 未激活，跳过防火墙配置（请自行确保 $LISTEN_PORT/udp 可达）"
fi

# ── 6. 冒烟 ──────────────────────────────────────────────
log "隧道状态："
wg show "$IFACE" | grep -E 'interface|public key|peer|allowed ips|latest handshake' || true
log "尝试 ping 对端 $PEER_TUNNEL_IP（对端未起时失败属正常）："
ping -c 2 -W 3 "$PEER_TUNNEL_IP" || log "ping 不通：确认对端已执行本脚本且 endpoint/公钥正确"
log "完成。对端档案请更新 assets/wireguard/peers.md（只记公钥，不记私钥）"
