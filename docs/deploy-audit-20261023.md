# 部署审计报告 — B/C 服务器 + 工具箱宝塔通道（2026-10-23）

范围：B（103.100.211.12 / deepquant.club）、C（177.4.41.137 / zhouchou.net）、本地工具箱 D:\Workspace\deploy。  
方法：两台各跑 22 项只读采集（nginx/supervisor/systemd/端口/进程/cron/acme/WireGuard/面板DB/权限/磁盘）→ 定点核查 → 零停机修复 → 回归验证（4 路由 + MCP initialize 均 200）。

---

## 一、非宝塔原生配置项清单

### B 服务器d

| #  | 配置项                                                                                   | 位置                                    | 来源                                                           | 影响/状态                                               |
| -- | ------------------------------------------------------------------------------------- | ------------------------------------- | ------------------------------------------------------------ | --------------------------------------------------- |
| 1  | 4 个站点 conf（html_deepquant-web/financial-web/financial-admin/official-site.local.conf） | vhost/nginx/                          | 工具箱部署+域名收编时手工重写路由                                            | 承载 /、/admin/、/qd/、/quant/、/api、ws、301；✅已对齐 html_ 命名 |
| 2  | /mcp 反代块（Host 伪装 127.0.0.1:7800、buffering off）                                        | html_financial-web.local.conf         | MCP streamable-http 修复时手工注入                                  | MCP 经域名访问必需；已验证 200                                 |
| 3  | mail.deepquant.club 绑定                                                                | financial-web 块 server_name           | 用户指定                                                         | 与 deepquant.club 共用站点，无 server_name 冲突              |
| 4  | supervisor ini ×4（financial-crawler/worker/streaming、quantdinger-mcp）                 | 面板 supervisor/profile/                | 工具箱 05 脚本生成；quantdinger-mcp 的 TRANSPORT=streamable-http 为手工改 | 伴随服务守护；env 均生效                                      |
| 5  | deploy.env.server-b                                                                   | /www/wwwroot/project/                 | 工具箱部署环境（含密钥）                                                 | 已收紧 600                                             |
| 6  | ufw：6379/5432 → 仅 1.192.39.234（家宽）                                                    | ufw 规则 14/15                          | 用户为本地开发直连 Redis/PG 特意放行（Redis-Local/PG-Local）                | Redis 有 requirepass；⚠️家宽 IP 变化后直连会断（预期）             |
| 7  | ufw：wg0 放行 5432,6379                                                                  | 规则 18                                 | 组网（C 经 WireGuard 读 B 的 Redis 分发）                             | 隧道正常（handshake 秒级）                                  |
| 8  | Redis bind 0.0.0.0 + requirepass；PG listen_addresses='*'                              | /etc/redis/redis.conf、postgresql.conf | 原生遗留                                                         | 被 ufw 兜住：仅家宽 IP + wg0 可达，公网不可达                      |
| 9  | acme.sh deepquant.club_ecc + reloadcmd 四路同步                                           | ~/.acme.sh/                           | 证书链路（06-fix-ssl-cert.sh）                                     | 有效期至 2027-01，自动续签                                   |
| 10 | 宝塔 cron ×3（哈希名：备份/日志切割）                                                               | /www/server/cron/                     | 面板生成                                                         | 正常                                                  |
| 11 | xray geodata cron、tailscaled                                                          | crontab/systemd                       | 用户自装（非项目组件）                                                  | 未动                                                  |
| 12 | 邮局栈 dovecot/postfix/rspamd（25/110/143/465/587/993/995 对外）                             | 系统                                    | 原生邮局（mail.deepquant.club 邮件服务）                               | 原生功能，未动                                             |
| 13 | market_data_center 目录                                                                 | /www/wwwroot/project/                 | 行情接入服务（已拉取本地留档）                                              | 当前未运行；目录权限 777→755 已收紧                              |

### C 服务器

| # | 配置项                         | 位置                            | 来源                     | 影响/状态                                                            |
| - | --------------------------- | ----------------------------- | ---------------------- | ---------------------------------------------------------------- |
| 1 | 4 个站点 conf（html_ 前缀）        | vhost/nginx/                  | 同 B（卓筹侧）               | financial-web 块含 zhouchou.net/www/mail.zhouchou.net + 全套路由 + 443 |
| 2 | /mcp 反代块                    | html_financial-web.local.conf | 手工注入                   | 已验证 200                                                          |
| 3 | supervisor ini ×4           | 同 B                           | 工具箱+手工                 | quantdinger-mcp token 为 C 侧独立值                                   |
| 4 | deploy.env.server-c         | /www/wwwroot/project/         | 工具箱                    | 已收紧 600                                                          |
| 5 | crontab：sync-mt5.sh 每 10 分钟 | crontab                       | ops/sync-mt5（MT5 数据同步） | 正常                                                               |
| 6 | wg0 peer B（10.10.0.2）       | /etc/wireguard/               | 组网                     | 正常                                                               |
| 7 | acme.sh zhouchou.net_ecc    | ~/.acme.sh/                   | 证书链路                   | 正常                                                               |
| 8 | 邮局栈（同 B 对外端口）               | 系统                            | 原生（zhouchou.net 邮件）    | 未动                                                               |
| 9 | Redis/PG 均绑 127.0.0.1       | 配置                            | 原生                     | ✅ 暴露面正确                                                          |

---

## 二、潜在问题排查与处置

### 已修复（零停机，均有备份）

| 问题                                                                           | 风险                                            | 处置                                                                  |
| ---------------------------------------------------------------------------- | --------------------------------------------- | ------------------------------------------------------------------- |
| B：financial-api/crawler/worker/streaming 四个 systemd 单元 **enabled 残留**（宝塔已接管） | 重启后 systemd 抢端口（有 quantdinger 崩溃循环 2284 次的前科） | 备份至 /root/systemd-backup-20261023/ → stop+disable+删单元+daemon-reload |
| B：quantdinger-backend.service.d 残目录（.#override.conf）                         | 单元目录脏                                         | 删除（已备份）                                                             |
| B：crontab @reboot 旧 quantdinger gunicorn（抢 5000）                             | 重启后与宝塔 Python 项目竞速                            | 删除该行（备份 /root/crontab-backup-20261023.txt）                          |
| C：financial-api.service enabled+failed 残留                                    | 同上                                            | 同样清除（已备份）                                                           |
| B/C：vhost 目录 .bak 残留（B 6 个、C 2 个）                                            | 目录脏、误 include 隐患                              | 移入 backup/vhost-bak-20261023/                                       |
| B：market_data_center 多个目录 777                                                | 权限过宽                                          | 收紧 755                                                              |
| C：official-site/dist 777                                                     | 同上                                            | 收紧 755                                                              |
| B/C：deploy.env.* 644（含 DB 密钥/密钥）                                             | 本机低权用户可读                                      | 收紧 600                                                              |
| B：uploads/dist 属主 UNKNOWN                                                    | 异常属主                                          | chown root:root                                                     |
| B：official-website 空目录残留                                                     | 命名混淆（qd 项目正名=official-site）                   | 删除                                                                  |

### 核查无恙（结论说明）

- **deepquant-backend gunicorn 绑 0.0.0.0:5000**：B/C 防火墙均未放行 5000（policy DROP），公网不可达；5001/7800 均绑 127.0.0.1。纵深防御可选改绑 loopback，但需重启后端，本次未动。
- **server_name 无冲突**：mail 子域绑定在 financial-web 单一 server 块内。
- **端口归属单一**：systemd 残留清除后，5000=宝塔 Python 项目、5001=宝塔 Python 项目、伴随服务=宝塔 supervisor，无双轨。
- **C 双 supervisor**：系统实例 conf.d 已空（仅剩 disabled 归档目录），真实守护全在宝塔实例。
- **磁盘**：B 49%、C 24%，健康。
- **MCP**：B/C /mcp initialize 均 200（注：streamable-http 必须带 `Accept: application/json, text/event-stream`，否则 406——客户端适配点）。

### 建议（已全部执行，2026-10-23 二轮）

1. ✅ **B 的 Redis 收紧绑定**：`/www/server/redis/redis.conf`（宝塔生效配置，注意 /etc/redis/redis.conf 是系统包残留不生效）`bind 0.0.0.0` → `bind 127.0.0.1 10.10.0.2`，`protected-mode no` → `yes`；重启 redis.service。验证：B 本机 PONG、C 经 WireGuard（10.10.0.2）PONG、B/C financial-api health `database: ok`。副作用：ufw 里 6379 家宽直连规则（Redis-Local）随之失效——本地开发 Redis 用 VM 的，不受影响；如需恢复家宽直连需在 bind 里加公网 IP。备份 /root/redis.conf.bak-20261023。
2. ✅ **deepquant-backend 改绑 127.0.0.1**（B/C）：源码 `deepquant/backend_api_python/gunicorn_config.py` 默认值 `'0.0.0.0'` → `'127.0.0.1'`（写回源码防复发），部署副本同步修改，面板 API RestartProject 重启（秒级窗口）。验证：两台 5000 均 LISTEN 127.0.0.1、本机探活 200、/quant/ 200、MCP initialize 200。备份 /root/gunicorn_config.py.bak-20261023。※源码改动待用户自行推送（deepquant 分支约定）。
3. ✅ **噪音日志清理**：B `financial-admin.local.error.log`（489KB，扫描噪音+旧日志错指遗留）、C `deepquant-web.local.error.log`（2.9MB）→ 归档至 `backup/logs-20261023/` 后 truncate 清零（inode 不变，nginx 无需 reload）。

**运维技巧记录**：服务器上手工调面板 API 的正确姿势——`eval "$(grep -E '^BAOTA_PANEL_URL=|^BAOTA_API_KEY=' deploy.env.server-X)"; export BAOTA_PANEL_URL BAOTA_API_KEY; python3 uploads/dist/channels/baota-api.py restart-python <项目名>`。⚠️eval 只建 shell 变量不 export，缺 export 则 python 子进程拿不到（首次踩坑实证）。

---

## 三、本次部署问题清单（描述 / 原因 / 措施 / 状态）

| #  | 问题                                                        | 原因分析                                                                                        | 解决措施                                                                    | 状态     |
| -- | --------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- | ------ |
| 1  | pack.ps1 tar 静默失败：输出"Packed"但文件未刷新，旧包被部署（favicon 退回 6 月版） | PS 沙箱环境 tar 行为异常，未复现根因                                                                      | tar 后新增新鲜度守卫（mtime+size 双检查，失败即中止）；bash tar 手工重打包                       | ✅已修+防御 |
| 2  | C 迁移"假成功"：dist 是旧版扁平布局                                    | tar 上传中断，残包被解压                                                                              | 全量重传+重新迁移；kind/frontend.sh 已有解压完整性 warn                                 | ✅已修    |
| 3  | WireGuard C→B 隧道断（Redis 预检失败）                             | B 的 wg0.conf 缺 C 的 peer（只留了已废弃的 A peer）                                                     | 补 peer 10.10.0.3 + wg syncconf                                          | ✅已修    |
| 4  | 面板建 Python 项目报"该端口已经被占用"                                  | 原生 systemd 单元（enabled+Restart=always）占 5000                                                 | stop+disable+删单元；工具箱守则「接管新机先清 systemd 双轨」                               | ✅已修    |
| 5  | RestartProject 卡"环境安装制作中"超时                               | 新建项目面板异步备环境 >60s                                                                            | 工具箱重试窗口 6→30 次（5 分钟）                                                    | ✅已修    |
| 6  | C 端口 5001 被系统级 supervisor 实例抢占                            | C 存在双 supervisor 实例，系统实例持有 financial-api ini                                                | 系统实例配置清空归档，统一宝塔实例                                                       | ✅已修    |
| 7  | AddDomain/SetSSL 面板 API 返回 404                            | 面板 11.8 API 模式禁用了部分写操作                                                                      | 手写 conf 443 块+证书落标准路径 vhost/cert/<站点>/+ acme.sh --install-cert 续签同步     | ✅已修    |
| 8  | /quant/assets 404                                         | vite base=/quant/ 但 assets 在 dist 顶层                                                        | 注入 location ^~ /quant/ alias + try_files                                | ✅已修    |
| 9  | zhouchou.net 首页显示"深量"                                     | 品牌取自 DB fin_app_configs（服务器端一直正确），浏览器 localStorage 缓存了迁移窗口的旧值                               | 服务器端确认正确；用户 Ctrl+F5                                                     | ✅澄清    |
| 10 | MCP /mcp 404 → 421 → SSE POST 挂起 三连                       | ①SSE 真实端点是 /sse 不是 /mcp；②FastMCP Host 校验拒非回环 Host；③mcp 1.30.0 SSE 传输 bug（stdio 对照实验证实服务端无罪） | 换 streamable-http 传输；nginx Host 伪装 127.0.0.1:7800；mcp 库 pin <2.0.0 写回源码 | ✅已修    |
| 11 | 改 supervisor ini 环境变量后 restart 不生效                        | supervisor 的 restart 不重读 ini                                                                | 手工 reread+update；工具箱 baota_restart_supervisor 已固化（见第四节 Fix1）            | ✅已修    |
| 12 | 面板「流量限制/网站日志/SSL」报错或为空                                    | AddSite 旧链路生成无前缀 conf，面板 html 类型按 html\_<名>.conf 读取（无兜底）                                    | 全站 conf/rewrite 改名对齐 html_ 约定；工具箱自愈（Fix2）                               | ✅已修    |
| 13 | /admin /qd /quant 不带斜杠 404                                | vite 子路径部署 + nginx 前缀匹配                                                                     | location = 精确匹配 301（用户自行推送后确认）                                          | ✅已修    |
| 14 | deepquant-web 日志写进 financial-admin 日志文件                   | B 的 deepquant-web conf 复制粘贴错误（rewrite include+日志路径）                                         | 审计中纠正                                                                   | ✅已修    |
| 15 | C financial-web 443 流量日志写通用 access.log                    | 收编迁移时遗留                                                                                     | 443 块日志改回站点文件                                                           | ✅已修    |

---

## 四、工具箱宝塔部署逻辑核对与修改

**核对结论**：意图模型（TOML routes/process/companions）、装载层、kind 流程、通道动词完备性（L1 测试 9/9 绿）总体合理。发现 3 个缺口，全部有今日线上实证，已直接修复：

### Fix1 — supervisor 重启前强制 reread+update（scripts/channels/baota.sh）

- **问题**：`baota_restart_supervisor` 只 `restart`；supervisor 的 restart 不重读 ini，environment/command 变更静默失效（今天 MCP 传输协议切换实证）。
- **修改**：restart 前补 `reread` + `update`（无变更时为 no-op，幂等安全）。

### Fix2 — 建站 conf 命名自愈（scripts/channels/baota-api.py + baota.sh）

- **问题**：AddSite 旧链路生成无前缀 conf，面板 html 类型功能（流量限制/网站日志/伪静态/SSL）读不到；工具箱 ensure 流程完全不校验。
- **修改**：baota-api.py 新增 `fix_html_conf_naming(site_name)`：①`<名>.conf`→`html_<名>.conf`（并存时旧件挪 .bak）；②rewrite 文件同步改名+touch 兜底；③conf 内 include 路径同步；④有改动时 nginx -t+reload。`add_html_site` 创建与已存在两条路径都调用（幂等），baota.sh 打印自愈提示。nginx 二进制带 `/www/server/nginx/sbin/nginx` 兜底。
- **验证**：B 机实测 4 站点全返回 None（零副作用），L1 全绿。

### Fix3 — Python 项目配置漂移检测（scripts/channels/baota.sh）

- **问题**：项目已存在时直接跳过，面板里手改过端口与 TOML 意图背离完全不可见。
- **修改**：exists 分支比对 `python-status` 返回的 port 与 TOML `process.port`，漂移即 warn 并给出纠正指引。

### 验证与未动项

- `bash -n` / `ast` 语法通过；`tests/run-all.sh` L1 回归 9/9 全绿；自愈函数实测幂等。
- **未动**：①financial-api 的 legacy deploy_hook（TOML 已标注"迁移完成后退役"，当前工作正常）；②宝塔通道"不碰 conf 内容"的所有权原则未破坏——Fix2 只做文件改名对齐面板原生约定，不做路由内容编写。

---

## 五、补充：防火墙统一与「宝塔面板可操作边界」（2026-10-23 追问后核实）

### 5.1 防火墙统一结论：两台底层本就统一，无需迁移

- **B、C 的防火墙底层均为 ufw 且 active**（默认 deny incoming）。之前在 C 上看到的"裸 iptables 白名单"实为 ufw 系列链 + 宝塔邮局插件直插的 mail ACCEPT 冗余副本（ufw 里同样有 mail 放行，语义重复、无害，动了会被邮局插件重插——保留不动）。
- **宝塔面板「安全→防火墙」页 = 两台的统一管理入口**：面板 11.x 的防火墙模块 `class/firewallModel/`（firewallBase.py + app/ufw.py）自动检测 ufw 并直接管理。已验证：面板模块 list_port 在 B 读到 32 条、C 读到 25 条规则。
- ⚠️ 注意：`class/firewall_new.py` 是旧遗留模块（其 GetList 在 ufw 上有 bug），面板 UI 不使用它——安全页请以面板界面为准。
- B/C 规则差异属角色差异（B 多：6379/5432 家宽直连、32768:32769 邮局 webmail、tailscale0、WG peer A），非配置不统一。

### 5.2 「宝塔面板可操作」边界清单（部署完毕后面板里能做什么）

| 操作 | 面板路径 | 状态 |
|------|----------|------|
| 站点列表/启停/删除 | 网站 → HTML/Python 标签页 | ✅ 原生可用 |
| 新增/删除域名 | 站点设置 → 域名管理 | ✅ 原生可用 |
| SSL 查看/更换 | 站点设置 → SSL | ✅ 已修复（此前 html_ 命名问题） |
| 流量限制 / 网站日志 / 伪静态 / 默认文档 | 站点设置 | ✅ 已修复可用 |
| **改路由/加子路径** | 站点设置 → 配置文件（官方编辑器，保存自动 reload） | ✅ 可用；复杂路由的"面板新增"路径 |
| 新增纯 HTTP 反代 | 站点设置 → 反向代理 | ✅ 原生可用（新增不重叠路径时无冲突） |
| Python 服务启停/日志 | 网站 → Python 项目 | ✅ 原生可用 |
| 伴随服务（crawler/worker 等） | 软件 → supervisor 插件 | ✅ 原生可用 |
| 防火墙端口放行 | 安全 → 防火墙 | ✅ 已验证（ufw，两台统一） |

**约定**：①后续新增简单 HTTP 反代 → 优先用面板"反向代理"功能；②复杂路由（本地目录 alias、需伪装 Host 的反代、精确 301）→ 面板"配置文件"编辑器直接改 conf；③SSL 自动续签走 acme.sh 链路，面板 SSL 页只读查看，**勿点面板的"续签"按钮**（会覆盖 acme.sh 链路）。

---

## 六、终验：部署符合性逐项核对（2026-10-23 第三轮，两台 40/40 全绿）

自检脚本：`scripts/tools/check-deploy.sh`（12 组 40 项，`BASE_DOMAIN=<生产域名> bash check-deploy.sh`，B/C 通用）。

| 组 | 项数 | 内容 |
|---|---|---|
| 1 | 9 | html_ 前缀 conf/rewrite ×4 站点 + include 同步 |
| 2 | 2 | nginx -t、server_name 同端口无重复（80/443 同名属标准设计） |
| 3 | 1 | 面板读取 日志/流量限制/SSL ×4 站点 |
| 4 | 7 | 4 子路径 200 + 3 无斜杠 301 |
| 5 | 2 | /mcp initialize 200、transport=streamable-http |
| 6 | 3 | 5000/5001/7800 全部仅绑 127.0.0.1 |
| 7 | 6 | 4 个 supervisor 程序 RUNNING、无 systemd 双轨、无 .service.d 残留 |
| 8 | 2 | 无旧 quantdinger cron、acme.sh cron 在位 |
| 9 | 2 | Redis bind 收紧（B 含 WG 地址/C 仅本机）、WG 握手正常 |
| 10 | 4 | deploy.env 600、无 777 目录、vhost 干净、无空目录残留 |
| 11 | 1 | 备份在位 |
| 12 | 1 | 面板注册 6 站点 |

**本轮发现并修复的不符项**：
1. 两台共 12 个部署产物目录 777（`*/package`、`*/dist`、备份目录）→ 全部收紧 755，页面回归 200（来源为历史手工操作，工具箱无 chmod 777）。
2. 核对脚本自身两处误报修正：server_name 查重改为按 listen 端口分组；Redis 判定改用宝塔生效配置路径（/www/server/redis/redis.conf，/etc/redis 为系统包残留）。

**项目级文档**（特殊配置与调整指南，含 conf 位置/参数/改法）：
- `project-configs/financial/DEPLOY-NOTES.md`
- `project-configs/deepquant/DEPLOY-NOTES.md`
- `project-configs/official-site/DEPLOY-NOTES.md`


