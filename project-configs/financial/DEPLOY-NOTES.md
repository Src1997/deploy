# financial 部署备注 — 特殊配置与调整指南（2026-10-23 定稿）

> 部署形态：宝塔全托管（B=深量 deepquant.club / C=卓筹商学院 zhouchou.net）。
> 常规操作走宝塔面板；本文只记**面板表达不了的特殊处理**和**改错了会炸的点**。
> 符合性自检：`BASE_DOMAIN=www.deepquant.club bash scripts/tools/check-deploy.sh`（40 项，B/C 通用）。

## 1. 站点与路由 conf（★最常调整）

| 站点（面板名） | conf 位置（B/C 相同） | 承载 |
|---|---|---|
| financial-web.local | `/www/server/panel/vhost/nginx/html_financial-web.local.conf` | `/` 行情社区前端 + `/api/`+`/api/ws` 反代 5001 + `/admin`、`/qd`、`/quant` 三组子路径 + `/mcp` + 生产域名（B: www.deepquant.club/deepquant.club/mail.deepquant.club；C: zhouchou.net/www.zhouchou.net/mail.zhouchou.net） |
| financial-admin.local | `/www/server/panel/vhost/nginx/html_financial-admin.local.conf` | 独立站点（备用；线上实际走 financial-web 的 /admin/ alias） |
| deepquant-web.local | `/www/server/panel/vhost/nginx/html_deepquant-web.local.conf` | deepquant 前端独立站点（/quant/ 的 alias 源） |
| official-site.local | `/www/server/panel/vhost/nginx/html_official-site.local.conf` | qd 渠道落地页（/qd/ 的 alias 源） |

- ★conf 文件名**必须带 `html_` 前缀**：面板对 html 类型站点的流量限制/网站日志/伪静态/SSL 一律按 `html_<站点名>.conf` 读取，无兜底（2026-10-23 实证）。工具箱 `baota-api.py fix_html_conf_naming` 会自愈。
- ★B 的 financial-web conf 是 80+443 **双 server 块**，server_name 相同属标准设计（勿"修复"）。
- 伪静态：`/www/server/panel/vhost/rewrite/html_<站点名>.conf`（面板"伪静态"编辑的就是它）。
- **调整方式**：面板 → 网站 → 站点设置 → 配置文件（保存自动 reload）；或 ssh 改后 `nginx -t && nginx -s reload`。
- 常用参数速查（都在 financial-web conf 内）：
  - `/api/` 反代目标：`proxy_pass http://127.0.0.1:5001/api/;`（端口对应 financial-api）
  - ws：`location /api/ws` 块内 `proxy_http_version 1.1; Upgrade/Connection 头`
  - 子路径静态源：`/admin/`→`alias .../financial-admin/dist;`、`/qd/`→official-site/dist、`/quant/`→deepquant/web/dist（deepquant 的 vite base=/quant/）
  - `/mcp`：`proxy_pass http://127.0.0.1:7800;` + **必须** `proxy_set_header Host 127.0.0.1:7800;`（FastMCP Host 校验）+ `proxy_buffering off;`
  - 无斜杠 301：`location = /admin { return 301 /admin/...; }` 三组
  - index.html 禁缓存：`/admin/` 与各 SPA 块内 `no-cache` 头

## 2. 后端与伴随服务

| 服务 | 托管 | 位置/参数 |
|---|---|---|
| financial-api（uvicorn :5001，绑 127.0.0.1） | 宝塔 Python 项目（面板可启停） | cmd/端口在面板项目配置；迁移命令 `alembic upgrade head`（TOML process.migrate），库内已到 mergepoint `m1g2h3i4j5k6` |
| financial-crawler / worker / streaming | 宝塔 supervisor 插件 | ini：`/www/server/panel/plugin/supervisor/profile/financial-*.ini`；**改 environment 后必须 `reread` + `update` 再 restart**（restart 不重读 ini） |
| 部署钩子 | legacy deploy_hook `scripts/deploy-python.sh` | 仅 financial-api 使用，迁移完成后退役；新项目勿模仿 |

- 手工重启 API（服务器上）：`eval "$(grep -E '^BAOTA_(PANEL_URL|API_KEY)=' /www/wwwroot/project/deploy.env.server-X)"; export BAOTA_PANEL_URL BAOTA_API_KEY; python3 /www/wwwroot/project/uploads/dist/channels/baota-api.py restart-python financial-api`
- ⚠️eval 提取的变量必须 `export` 才能传给 python 子进程。

## 3. 证书

- acme.sh 自动续签（`/root/.acme.sh/deepquant.club_ecc`（B）/ `zhouchou.net_ecc`（C）），reloadcmd 走四路同步（网站/面板/邮局/其余站点）。
- 证书落位：`/www/server/panel/vhost/cert/<站点或域名>/`（B=financial-web.local、C=www.zhouchou.net），conf 内 `ssl_certificate` 指向这里。
- ⚠️面板 SSL 页**只读查看，勿点"续签"**——会覆盖 acme.sh 链路。
- B 证书同步工具：`scripts/ops/06-fix-ssl-cert.sh`（bt-cert-sync.sh）。

## 4. 品牌双标（深量/卓筹）

- 品牌名存 DB：`fin_app_configs` 表 `brand.name`（B=深量科技，C=卓筹商学院）——改品牌改 DB，不是改前端。
- favicon：源码 `public/favicon-sl.ico`（深量）/`favicon-zc.ico`（卓筹），index.html 内联 domain→brand MAP 运行时选择（防闪烁）。
- 用户端浏览器 localStorage 可能缓存旧品牌 → Ctrl+F5。

## 5. 跨服务器约定

- C 的 Redis/行情：**不落本地库**，经 WireGuard（10.10.0.2）读 B 的 Redis 分发；B 的 Redis 已绑 `127.0.0.1 10.10.0.2`（`/www/server/redis/redis.conf`，改动需 `systemctl restart redis`）。
- C 端 MT5 数据：crontab 每 10 分钟 `/opt/sync-mt5.sh`（源自 ops/sync-mt5）。
- 防火墙：两台均为 ufw（面板「安全→防火墙」统一管理）；B 的 6379/5432 仅对家宽 IP + wg0 放行。

## 6. 数据库迁移红线

- alembic 版本链含 mergepoint `m1g2h3i4j5k6`；**新迁移必须基于 mergepoint 之后**，否则多 head。
- 部署钩子失败禁止降级 warn——「新代码+旧 schema」中间态不可上线。
