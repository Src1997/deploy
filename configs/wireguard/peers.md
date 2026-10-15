# WireGuard 对等档案（Peers Registry）

> 记录跨机隧道的网段规划与**公钥**。私钥只存在于各机 `/etc/wireguard/<name>.key`，**禁止入库**。
> 重建隧道：各机重跑 `scripts/tools/setup-wireguard.sh`（幂等）；换机/换密钥后更新本表。

## 网段规划

| 网段 | 用途 |
|------|------|
| `10.10.0.0/24` | 服务器间内网（WireGuard）。按接入顺序分配 `.1/.2/...`，VM/新机继续顺延 |

## 当前对等关系

| 机器 | 公网 endpoint | 隧道 IP | 公钥 | 监听端口 | 状态 |
|------|---------------|---------|------|----------|------|
| server-a（阿里云 HK，121.41.44.216） | 121.41.44.216:51820 | 10.10.0.1/24 | `4hVZp8G+XBF1QYIrBudpnR2gWYrvDzpdHZBt6syrIR4=` | 51820/udp | 活跃（2026-10-15 建） |
| server-b（亿速云 HK，103.100.211.12） | 103.100.211.12:51820 | 10.10.0.2/24 | `i3T9Buyn2mLcbLHWE8WWJ/ViJ7bWKCNHlriXiC/JUUc=` | 51820/udp | 活跃（2026-10-15 建） |

## 隧道承载的业务流量

| 流量 | A 侧配置 | B 侧端口 | 说明 |
|------|----------|----------|------|
| financial Redis（db0 业务 / db1 arq 队列） | `.env` REDIS_URL / ARQ_REDIS_URL → `10.10.0.2:6379` | 6379 | B ufw 仅放行 wg0 接口 + 1.192.39.234（本地家宽） |
| financial MT5 三表（fdw） | A 库 fdw SERVER `fin_mt5_b_srv` host → `10.10.0.2` | 5432 | B pg_hba `10.10.0.1/32` scram |
| 未来新服务 | 直接指向对端隧道 IP | — | ufw 只需 `allow in on wg0`，无需逐公网 IP 放行 |

## 防火墙三层口径（新机接入照此办理）

1. **ufw（入口）**：对端 endpoint 公网 IP → 51820/udp；业务端口只放行 wg0 接口（**不要**再对公网 IP 放开）
2. **服务 bind**：PG `listen_addresses='*'` 依赖防火墙收敛；Redis requirepass 必须有
3. **pg_hba**：按隧道网段逐条加（如 `10.10.0.1/32 scram-sha-256`），禁止 `0.0.0.0/0` 全网规则（MT5 bridge 停用期已注释，恢复后按 Tailscale IP 收窄放开）

## 挂账

- B pg_hba 中 MT5 bridge 的 `root 0.0.0.0/0` 已注释（2026-10-15，bridge 停用期）；bridge 恢复时按 Windows 实体机 Tailscale IP（100.x）加回精确规则。
