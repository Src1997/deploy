# 系统评审修复进度 — 2026-11-25

> 清单来源：[system-review-bug-optimization-2026-11-25.md](./system-review-bug-optimization-2026-11-25.md)
> 仓库分支：financial-api / financial-web `future/sunrc_test`

## P0（安全红线，当日完成代码落地）

| # | 问题 | 状态 | 提交 / 证据 |
|---|------|------|------------|
| X10 | mt5-bridge-service 不在 git 管控 | ✅ 已落实 | api `bf97002`：迁入 `financial-api/mt5-bridge/`（32 文件，密钥/日志/bak 双 .gitignore 防线），原目录归档 `mt5-bridge-service.archive-20261125`（含本地 venv/密钥，确认稳定后可删）；deploy `project.toml` source_path → `financial/financial-api/mt5-bridge`；桥 43 测试过 |
| T2 | 桥生产裸奔（0.0.0.0 + 空 token 仅告警） | ✅ 已落实（代码+winvm） | api `df9006d`：非回环+无 token 拒绝启动（RuntimeError）；winvm config.ini 本就回环（2026-11-23 已改）+ 新增 api_token（`6c2f5ca2…`，存 deploy/tmp/t2-token.txt）；RCC `ea.api_token` 同值；桥重启三态验证 health 200 / 无token 401 / 带token 200；api 重启后 `/rates` 调桥带 token 200 实证 |
| A1 | EA 归属校验被白名单短路（跨用户越权） | ✅ 已落实 | api `2a4fee9`：`_ensure_login_allowed_for_user` 白名单不再短路登录态（None/命中均继续过 `resolve_user_logins`）；无归属渐进期放行保留；测试重写 3 例，50 passed |
| A2 | MT5 投资者密码明文落库 | ✅ 代码落地 / ⏳ winvm 部署待执行 | api `c2b4475`：`app/core/crypto.py` + `EA_MT5_PASSWORD_FERNET_KEY`（空密钥 fail-fast）+ add_account 加密落库；桥 `app/crypto.py` 解密（历史明文兼容）+ settings `[security] fernet_key` + collector 读库解密；迁移脚本 `mt5-bridge/scripts/migrate_password_encrypt.py`（列宽 256→512 + 明文批量加密，幂等）；api/桥单测 12+4 例。**winvm 待办**：① 生成 key 已存 deploy/tmp/a2-fernet-key.txt；② api .env 加 `EA_MT5_PASSWORD_FERNET_KEY`；③ 桥 config.ini 加 `[security] fernet_key`；④ 三端打包部署；⑤ 跑迁移脚本（先 --dry-run） |
| D5 | /docs 生产暴露接口面 | ✅ 已落实 | api：`create_app` docs_url/redoc_url/openapi_url 按 `is_production` 关闭；单测 2 例 |
| W3 | EA 接口失败静默降级假 mock | ✅ 已落实 | web `39d09f2e`：ea-account/index.ts 6 处 catch→getMock 加 `import.meta.env.DEV` 门禁，生产抛错走 UI 错误态；顺手修 2 处既有 lint 错误 + 清 scripts_tmp；vue-tsc 过 |

## P1（稳定性，当日完成代码落地）

| # | 问题 | 状态 | 提交 / 证据 |
|---|------|------|------------|
| T1 | MT5 IPC 四执行流三把锁互不相干（并发随机 -10004） | ✅ 已落实 | api `315bfc7`：`_lock` 改 RLock 作为唯一 MT5 IPC 锁；移除独立 `_rates_lock`；`_build_publish_payloads`（锁外调 mt5.*）与 `_run_verify`（mt5.login）全部纳入锁内；桥 47 测试过 |
| T3 | WS 端点事件循环内跑同步重计算 | ✅ 已落实 | api `b097399`：WS 循环内 drain_events / get_equity_history（50 万点聚合+DB 回退）改 `asyncio.to_thread` |
| T4 | /accounts/verify 同步 sleep 占死线程池 | ✅ 已落实 | api `b097399`：改 async 端点 + `asyncio.sleep(0.5)`，不再占线程池 worker |
| A5 | JWT aud 全局不校验 + refresh token 可进 WS | ✅ 已落实 | api `422e303`：本地 JWT 访问令牌 aud 白名单（client/admin/impersonation）；`create_app` 改调用时读 get_settings()（修复测试顺序污染）；6 例单测 |
| A6 | WS 鉴权绕过会话吊销/用户状态 | ✅ 已落实 | api `422e303`：WS 握手从只验签名收敛到 `authenticate_token`（与 get_current_user 共用 aud/FinUser.status/jti 吊销校验）；全量 unit 748 passed |
| M1 | admin HTTP 客户端无超时 | ✅ 已落实 | admin `98bb703`：authedFetch 未传 signal 默认 `AbortSignal.timeout(15s)` + 超时可读文案；vue-tsc 过 |
| M2 | admin 列表加载竞态（旧响应覆盖新响应） | ✅ 已落实 | admin `98bb703`：useCrudList reload 请求序号，过期响应丢弃 |
| D1 | -NoRestart + 守护拉起 → 旧代码进程残留 | ✅ 已落实 | deploy `10b3149`：-NoRestart 时 user-session 组件停旧进程等守护拉起（service 形态无守护，维持跳过） |
| D2 | 孤儿 uvicorn 占端口 | ✅ 已落实 | deploy `10b3149`：service 重启改 stop → `Stop-PortOrphans` → start |
| D3 | 健康门失败不自动回滚 | ✅ 已落实 | deploy `10b3149`：失败且存在备份时自动回滚 latest；无备份明确报错 |
| D4 | preflight 不覆盖 user-session | ✅ 已落实 | deploy `10b3149`：preflight 增加计划任务存在性 / 启动脚本 *.bat 在位 / config.ini 端口一致性校验 |
| X8 | alembic 迁移失败静默继续启动 | ✅ 已落实 | api `91436dd`：生产 fail-fast 抛出阻止启动（配合 D3 健康门自动回滚）；非生产保持容错；3 例单测，全量 unit 751 passed |

## P0 部署验证（winvm 192.168.31.200）

- ⏸ **受阻**：winvm SSH/ping 全部不可达（虚拟机疑似挂起/关机），待机器恢复后按以下顺序执行：
  1. 分发 Fernet key（api .env / 桥 config.ini）
  2. `pack.ps1 mt5-bridge` + deploy（`-NoRestart` + `schtasks /run /tn mt5-bridge`）——新桥代码兼容明文
  3. `pack.ps1 financial-api` + deploy（重启，RCC 缓存重载 + A2 加密写库 + D5 docs 关闭 + A1 生效）
  4. 迁移脚本 dry-run → 正式跑（DB 明文 → 密文）
  5. `financial-web` build:prod + deploy（W3）
  6. 验证：`/api/health` 200；`/docs` 404（生产）；首页 title「深量科技」；桥采集入库正常；`fin_mt5_accounts.password` 全为 gAAAA 密文

## 文档同步

- ✅ 桥 [API_DOC.md](../../financial/financial-api/mt5-bridge/API_DOC.md)：认证段改 X-Api-Token + 拒绝启动说明 + A2 加密说明 + 手工插库改密文示例
- ✅ 桥 config.example.ini：T2 硬防线 + [security] fernet_key 段
- ✅ api .env.example：EA_MT5_PASSWORD_FERNET_KEY 生成/分发说明
- ✅ 评审文档：P0 六项 + P1 全部 12 项加【已落实 2026-11-25】标记

## P2（2026-11-26 落实）

| # | 问题 | 状态 | 提交 / 证据 |
|---|------|------|------------|
| T8 | 历史净值重建漏出入金 | ✅ 已落实 | api `68a3305`：_seed_equity_history 回放全部成交（交易类 profit+swap+commission / balance 类 profit），基准从当前净值扣全部增量反推；6 例新单测，桥 53 passed |
| T9 | K 线时间未做券商服务器时区换算 | ✅ 已落实 | api `68a3305`：_server_tz_offset/_mt5_time_to_utc（NY DST 自动推断 + `[mt5] server_tz_offset_hours` 可配，按 UTC 日期缓存）；fetch_rates K 线与净值回放点统一真实 UTC；API_DOC 补 /rates 与 verify 端点 + 时间口径说明 |
| A3 | fin_mt5_snapshots 无索引 + 全表聚合 | ✅ 已落实 | api `2be1af3`：_latest_snapshot_rows 改 DISTINCT ON (login)；alembic `a3b4c5d6e7f8` 补 idx_fin_mt5_snapshots_login_time（与桥 DDL 同名幂等）；api 751 passed |
| T7 | 轮询重复全量传输（/rates 无缓存 + account-info 全量 deals） | ✅ 已落实 | api `2be1af3`：桥 /account-info 与 /rates 响应 TTL 缓存（默认 3s，`[server] response_cache_ttl_sec`），D8 overview 同根受益；桥 58 passed |
| W4 | 首页板块零错误态 | ✅ 已落实 | web `43f0b839`：showSectionError 分支（提示+重试），error 返回值不再无人消费 |
| W5 | 30s 轮询不感知页面可见性 | ✅ 已落实 | web `43f0b839`：新增 useVisibilityAwareInterval（后台暂停/恢复立即刷新），接入 useAsyncData pollingInterval 通道 + GoldTrendFeed |
| W1 | refresh token 明文 localStorage | ✅ 已落实 | api `591a631` + web `0c270a13`：LoginResult 全端点 Set-Cookie `fin_refresh_token`（httponly/lax/secure，续期回写，logout 清除）；/auth/refresh body 优先 Cookie 兜底；web 改内存存储+存量迁移，不再落 localStorage；api 756 passed / web 123 用例过 |
| W2 | WS/OAuth/代登 token 走 URL query | ✅ 已落实 | api `591a631` + web `0c270a13`：WS 首帧 `{"type":"auth","token"}` 握手（先于订阅，认证后 conn.user 升级；query token 过渡期兼容）；OAuth/imp_token 已有读后 replaceState 清理 |
| X13 | admin 无 lint/CI/工程化门禁 | ✅ 已落实 | admin `a08d8d8`：ESLint flat config（基线对齐 web）+ lint 脚本 + 310 存量错误清零 + GitHub Actions CI（软链 ../financial-web 匹配 build 跨仓审计）+ AGENTS.md；eslint 0 错误 / vue-tsc / vitest 129 过 |
| X14 | audit 脚本隐性跨仓依赖 + schema 双仓无比对 | ✅ 已落实 | web `7ab38b50` + admin `d1942d1`：api-field-audit.mjs 迁入 web/packages/contracts/scripts/（resolveWebRoot/resolveAdminRoot），admin 改调同一实体；admin api-sync --check 增 schema.d.ts 字节级比对防漂移 |
| X1 | fin_mt5_* 表三个 DDL 来源无 SSOT | ✅ 已落实 | api `bfab093`：桥 db.py::_TABLES_DDL_TEMPLATE 为 DDL 唯一 owner（init_tables.sql 镜像 + test_ddl_parity 门禁）；alembic `b5c6d7e8f9a0` 只读校验九表存在；api _ensure_ingest_tables 每进程一次 to_regclass 探测 + 生产缺表 fail-fast + 非生产幂等补齐 |
| X2 | 桥↔api 契约四通道四种口径 | ✅ 已落实 | api `9125801` + deploy project.toml：新增仓库根 contracts/ 共享 pydantic 包（零 app 依赖）——QuoteTick（Redis 行情，api QuoteSnapshot 改继承）/ IngestPayload（ingest，api schemas 改 re-export）/ RatesResponse（/rates 响应 typed 解析）三通道 SSOT；桥 _build_publish_payloads/_build_ingest_payload/get_rates 改构造契约模型（单条校验失败跳过不中断采集）；打包经 deploy mt5-bridge extra_source 搭车进 package/contracts（DryRun 已验证）；/accounts/verify 保留 API_DOC 文档化；api 775 / 桥 60 测试过。四通道中 DB 通道由 X1 收敛 |

## P2 文档同步

- ✅ 评审文档：T8/T9/A3/T7/W4/W5 + X13/X14/X1/X2 已加【已落实 2026-11-26】标记
- ✅ 桥 API_DOC.md：/rates 与 /accounts/verify 端点补录 + T9 时间口径统一说明 + §0 契约 SSOT（contracts 三通道模型索引）
- ✅ 桥 config.example.ini：server_tz_offset_hours（T9）+ response_cache_ttl_sec（T7）

## 后续

- P0+P1+P2 部署验证：winvm 仍未恢复（2026-11-25 下午起 ping/SSH 不可达，2026-11-26 复测仍不可达）；P1/P2 代码项随 P0 部署一并生效。恢复后按 P0 节顺序执行，额外验证：桥并发采集/行情无 -10004；WS 重客户端不假死；admin 慢请求 15s 超时提示；A3 索引生效（EXPLAIN /summaries 查询走 idx_fin_mt5_snapshots_login_time）；/rates 二次请求 <50ms（TTL 缓存命中）；桥重启后 contracts 导入正常（X2 打包搭车，svc_entry 兜底 sys.path）
- 评审清单分级落实已全部完成（P0 六项 / P1 十二项 / P2 全部代码项）；未列入本轮的架构项（X3-X7、X9、X11、X15-X20 等）与中低危项按清单 §七 修复路线另行排期
