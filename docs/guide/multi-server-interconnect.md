# 多服务器互联方案（Server-to-Server Interconnect）

> 适用场景：A/B/VM 之间需要共享 Redis、数据库、未来可能的 MQ / 对象存储 / 新服务。
> 目标：**一条加密通道收敛所有跨机流量**，新服务接入零防火墙改动。

## 决策树

```
两台服务器之间要打通什么？
├─ 高频双向访问（Redis / PG / 未来的 MQ、缓存、注册中心）
│   └─ ✅ WireGuard 隧道（本仓默认方案，见下）
│       └─ 跨库只读查询？→ 在隧道之上用 postgres_fdw 外部表（代码零改动）
├─ 低频 / 一次性文件同步
│   └─ scp / rsync over SSH（22 端口已白名单，不另开通道）
└─ 公网面向用户的流量
    └─  Cloudflare CDN
```

**不要**再逐服务开公网端口（ufw allow from <对端IP> to any port <svc>）——端口越开越多、
全程明文、PG 加密还得重编译。2026-10-15 已把 A↔B 的 Redis/PG 从公网直连全部收编到隧道。

## WireGuard 快速上手

各机跑一次 `scripts/tools/setup-wireguard.sh`（幂等，装包/密钥/配置/自启/ufw 全包）：

```bash
# 机器1（例：server-a，隧道 10.10.0.1）
bash scripts/tools/setup-wireguard.sh --name a --tunnel-ip 10.10.0.1/24 \
  --peer-name b --peer-public-key <B公钥> \
  --peer-tunnel-ip 10.10.0.2 --peer-endpoint 103.100.211.12:51820 \
  --allow-ports 6379,5432

# 机器2（例：server-b，隧道 10.10.0.2）
bash scripts/tools/setup-wireguard.sh --name b --tunnel-ip 10.10.0.2/24 \
  --peer-name a --peer-public-key <A公钥> \
  --peer-tunnel-ip 10.10.0.1 --peer-endpoint 121.41.44.216:51820 \
  --allow-ports 6379,5432
```

当前对等关系与公钥：`configs/wireguard/peers.md`。

### 已踩过的坑（照此避雷）

1. **ufw 对 wg0 接口必须显式放行**：WG 进来的包同样过 INPUT 链，
   `ufw allow in on wg0 to any port 6379,5432`，否则隧道通了服务端口照样不通。
2. **宝塔 PG 的真实 data 目录可能在 `/data/postgresql/data`**（`/www/server/pgsql/data`
   是另一份拷贝），改 pg_hba.conf / reload 前先用 `ps aux | grep 'postgres.*-D'` 确认。
3. **pg_hba 按隧道网段加规则**， reload 用
   `su - postgres -c '/www/server/pgsql/bin/pg_ctl reload -D /data/postgresql/data'`。
4. **改 .env 后必须重启全部四个服务**（api/crawler/worker/streaming）——只重启 api
   会让其他进程带着旧地址跑，表现为间歇性 Redis 超时（2026-10-15 实测）。
5. **A 的 1C2G 跑 wg 零感**：内核态转发，不用顾虑资源。

## postgres_fdw 外部表（跨库只读）

```sql
-- 读端机器（例：A 的 quant_zc 库）
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE SERVER <name>_srv FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host '<对端隧道IP>', dbname 'quant_zc', port '5432');
CREATE USER MAPPING FOR <user> SERVER <name>_srv
  OPTIONS (user '<user>', password '<对端密码>');
IMPORT FOREIGN SCHEMA public LIMIT TO (表1, 表2) FROM SERVER <name>_srv INTO public;
-- 换地址（如切隧道 IP）：ALTER SERVER <name>_srv OPTIONS (SET host '<新IP>');
```

现成案例：A 库 `fin_mt5_b_srv` → B 的 `fin_mt5_accounts/snapshots/deals` 三表
（MT5 bridge 数据只写 B，A 的接口零改动直读）。

## 新服务器接入清单

1. 跑 `setup-wireguard.sh`（向 peers.md 顺延分配隧道 IP）
2. 对端机器补一条 Peer（Endpoint 指向新机公网 IP）后 `wg-quick down wg0 && wg-quick up wg0`
3. ufw 只放 51820/udp（对端 IP）；业务端口走 wg0 接口放行
4. PG 类：pg_hba 加隧道网段规则；Redis 类：确认 requirepass
5. 应用的 .env / fdw 指向**对端隧道 IP**（不再写公网 IP）
6. 更新 `configs/wireguard/peers.md`（公钥、网段、承载流量）
