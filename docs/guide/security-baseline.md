# 安全基线（B/C 生产暴露面与权限约定）

> **Category**: Guide
>
> 沉淀自 2026-10-23 全面审计（详见 [deploy-audit-20261023.md](../deploy-audit-20261023.md)）。
> 用途：①新机器装机对照；②改动后回归对照；③安全自查入口。
> 逐机实测自检：`BASE_DOMAIN=<生产域名> bash scripts/tools/check-deploy.sh`（40 项）。

## 1. 暴露面基线（对外只开该开的）

| 项 | 基线 | 违例后果 |
|----|------|----------|
| 对外端口 | 仅 80/443（web）+ 面板端口（改过默认）+ 邮局 25/465/993 | 扫描面扩大 |
| Python 服务绑定 | financial-api(5001) / deepquant-backend(5000) / quantdinger-mcp(7800) **全部绑 127.0.0.1** | 直连绕过 nginx 鉴权/限流 |
| Redis | `bind 127.0.0.1 10.10.0.2`（宝塔 WG）+ `protected-mode yes`，密码必配 | 0.0.0.0 = 未授权访问经典事故 |
| PostgreSQL | 5432 仅家宽 IP + wg0（ufw 放行），无 0.0.0.0 | 拖库 |
| 生效配置路径 | Redis 用 `/www/server/redis/redis.conf`（redis.service）；`/etc/redis/` 是系统包残留**不生效** | 改错文件以为已加固 |

## 2. 防火墙：ufw 一元化管理

- B/C 均为 **ufw active**（默认 deny incoming），统一从**宝塔面板 → 安全 → 防火墙**增删规则（底层即 ufw，B 32 条 / C 25 条）。
- **勿手插裸 iptables 规则**——与 ufw 并存难审计（C 的 mail ACCEPT 是宝塔邮局插件直插的冗余副本，无害但保留）。
- `class/firewall_new.py` 是面板旧遗留（UI 不用），勿据其排查。

## 3. 文件权限基线

| 对象 | 基线 |
|------|------|
| 部署产物目录（package/dist/backup/uploads） | **755**（审计曾发现 12 处 777 历史遗留，已收紧） |
| `deploy.env*` / 项目 `.env` | **600**（含全部密码，泄露=拖库+挖矿） |
| 站点 `.user.ini` | chattr +i 锁定（防跨站），部署时解锁→还原 |
| nginx conf 备份 | 归档到 `backup/vhost-bak-<日期>/`，不留散落 .bak |

## 4. 面板安全

- API 接口：`api.json` 用 **token 字段**签名（不是 key）；`limit_addr` 必须含 `127.0.0.1`（部署脚本本机调用）且按需收敛来源。
- `BAOTA_API_KEY` 只存在服务器 `deploy.env.server-X`（600），**严禁进 git**（L1 第 8 项有 gitignore 防线）。
- 面板端口/安全入口/登录限制按宝塔面板安全设置维护；证书见 [ssl-certificates.md](./ssl-certificates.md)。

## 5. 双轨与残留红线（防「加固被自己拆掉」）

1. 宝塔机**禁 systemd 业务单元**、**禁 cron @reboot 拉服务**——2026-10-23 已全部清除（备份在两台 `/root/systemd-backup-20261023`、`/root/crontab-backup-20261023.txt`），勿回加。
2. 旧 conf 只进 `backup/` 归档，不留在 vhost 目录（nginx 加载即生效）。
3. 噪音 error.log 只归档+truncate，勿直接 rm 正被写的日志文件。

## 6. 周期自查建议

| 频率 | 动作 |
|------|------|
| 每次部署后 | `check-deploy.sh` 40 项（含端口绑定/权限/双轨/Redis bind 判定） |
| 每周 | `ss -tlnp` 人工过一遍监听面；`last -20` 登录记录；`df -h` 水位 |
| 每月 | 密码轮换评估（改 Redis 密码需同步 deploy.env + .env + 重启依赖服务）；`apt list --upgradable` 安全补丁 |
| 证书 | acme.sh 自动续；到期前人工确认一次（`acme.sh --list`，见 [ssl-certificates.md](./ssl-certificates.md)） |

> 加固改动的顺序纪律：**先备份（/root/*.bak-<日期>）→ 改 → 服务重启 → check-deploy 回归**。
