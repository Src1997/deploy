# 全系统深度梳理 · Bug 与优化清单 v2（2026-11-25）

> 测试方法：外部运行时冒烟（192.168.31.200 实测）+ 四模块并行深度代码审查（api / C 端 web / admin / mt5-bridge，逐文件追踪调用链，结论均带行号证据）+ 架构与文件结构审查（分层一致性/契约带/模块耦合/工程化基线）+ 部署链实战演练复盘。
> 系统：financial-web(C端) · financial-admin(后台) · financial-api(FastAPI:5001) · mt5-bridge(FastAPI:9199, MT5 IPC) · PG(postgresql-quant) · Redis(宝塔) · 宝塔 nginx。
> 编号规则：A=api W=web M=admin T=桥 D=部署链 X=架构（§五为部署链运行环境，§六为架构与文件结构，§七为修复路线）。

## 严重度总览

| 级别 | 数量 | 代表问题 |
|---|---|---|
| 高危 | 8 | EA 账号越权读他人资金、MT5 交易密码明文落库、桥 0.0.0.0 无 token 裸奔、MT5 IPC 四线程并发无互斥、WS 事件循环阻塞、C 端 token 明文 localStorage、EA 数据失败静默降级假资金 mock |
| 中危 | 24 | JWT aud 不校验、WS 绕过会话吊销、debug=True 验证码进日志、全文件 SHA-256 N+1、后台请求无超时/竞态、MT5 两页无前端门禁、代登 token 入 URL、终端掉线仍报健康、历史净值漏出入金、K 线时区偏移 |
| 低危 | 20+ | 文案硬编码、图片 lazy、死代码、无连接池等 |

---

## 一、financial-api（后端）

### 高
- **A1. EA 账号归属校验被白名单短路（跨用户越权）** — [ea_account/service.py:152-154](file:///D:/Workspace/financial/financial-api/app/domains/market/ea_account/service.py#L152-L154)：`_ensure_login_allowed_for_user` 在 RCC `ea.visible_logins` 未配置（默认 None）时直接放行，任何登录用户 `?login=任意账号` 可读他人余额/净值/成交（/summary、/deals、/equity-history）。修复：登录用户一律先过 resolve_user_logins 归属校验，白名单只决定匿名可见。【已落实 2026-11-25 api 2a4fee9，测试重写 50 passed】
- **A2. MT5 投资者密码明文落库** — [add_account.py:215-228](file:///D:/Workspace/financial/financial-api/app/domains/market/ea_account/add_account.py#L215-L228)：`fin_mt5_accounts.password` 无加密（DDL 无加密字段）。DB 泄露即可动真实资金。修复：Fernet/KMS 加密，仅桥侧解密。【已落实 2026-11-25 api c2b4475：app/core/crypto.py + 桥侧解密兼容明文 + 迁移脚本；winvm 部署与存量迁移待执行】
- **A3. fin_mt5_snapshots 无索引 + 每请求全表聚合** — 建表仅主键（mt5_collector/service.py:65-77），/summaries 轮询执行 `GROUP BY login` 全表聚合，随采集线性劣化。修复：建 `(login, created_at DESC)` 索引 + DISTINCT ON。【已落实 2026-11-26 api 2be1af3：查询改 DISTINCT ON + alembic a3b4c5d6e7f8 补索引（与桥 DDL 同名幂等），api 751 测试过】

### 中
- **A4. debug 默认 True → 验证码进生产日志** — `_server.py:15`；email/sms codes.py 只看 debug 门。
- **A5. JWT aud 全局不校验 + refresh token 可进 WS** — [auth.py:55](file:///D:/Workspace/financial/financial-api/app/core/security/auth.py#L55)；WS 路径（realtime/router.py:31）不拦 aud=refresh，30 天 refresh token 可完成聊天/QA 鉴权。【已落实 2026-11-25 api 422e303：本地 JWT aud 白名单（client/admin/impersonation）+ 新增 6 例门禁单测】
- **A6. WS 鉴权绕过会话吊销/用户状态** — realtime/router.py:29-41 只验签名，不查 jti 吊销与 FinUser.status；被禁用户 7 天内仍可用 WS。【已落实 2026-11-25 api 422e303：WS 握手收敛到 authenticate_token（与 get_current_user 共用 aud/用户状态/会话吊销校验）】
- **A7. 资源列表逐条全文件 SHA-256** — resources/access.py:65-78，100 条/页≈200 次全文件哈希同步阻塞。改 DB 状态位。
- **A8. 代理工作台资金 float 累加** — agents/workbench.py:65,111-123，DB 是 NUMERIC(14,2)，float 求和分位漂移 + memberCount N+1（L155）。
- **A9. /add-account/verify 可作 MT5 密码爆破跳板** — router.py:51-62 无 per-user 频控（全局限流 200/60s 太宽），单次等待 45s 占线程池。
- **A10. 上游认证每请求新建 Client** — auth/upstream/client.py:72-77，无重试/熔断，上游抖动拖垮线程池。

### 低
- **A11.** WS token 走 query string 进访问日志（realtime/router.py:20）→ 改首帧握手。
- **A12.** legacy sha256 弱哈希永续接受（auth.py:71-73）→ 登录时静默升级 bcrypt。
- **A13.** /api/trade/symbols/list 显式无分页（trade/router.py:41）。
- **A14.** 沙箱回调端点未配密钥时 500（payment/sandbox.py:51-52 + router.py:93-97 无鉴权）→ 前置 404。

> 正面确认：CORS 非通配、支付整数分+HMAC+快照价、admin 端点均挂 AdminUser/capability、SQL 基本参数化、资金落库 NUMERIC/分。

---

## 二、financial-web（C 端）

### 高
- **W1. access/refresh token + 用户资料明文 localStorage** — [auth/index.ts:93-100](file:///D:/Workspace/financial/financial-web/src/core/api/auth/index.ts#L93-L100)：XSS 即全量接管（401 自动续期放大 refresh 价值）。修复：refresh 改 httpOnly Cookie。【已落实 2026-11-26 api 591a631 + web 0c270a13：全部 LoginResult 端点 Set-Cookie fin_refresh_token（httponly/samesite=lax/secure 按 is_production，滚动续期回写，logout 清除）；/auth/refresh body 优先 Cookie 兜底；web refresh token 改内存存储+存量迁移清理，不再落 localStorage；api 756 passed / web vue-tsc+123 用例过】
- **W2. WS/OAuth/代登 token 全部走 URL query** — websocket/url/index.ts:31-33 等，进网关日志/历史/Referer。改首帧握手或 Sec-WebSocket-Protocol。【已落实 2026-11-26 api 591a631 + web 0c270a13：WS 改首帧 {"type":"auth","token"} 握手（先于订阅消息，conn.user 认证后升级，query token 过渡期兼容）；OAuth 回调与代登 imp_token 已有读后 replaceState 清理，无需额外改动】
- **W3. EA 资金接口失败静默降级为假 mock 数据** — [ea-account/index.ts:88-98](file:///D:/Workspace/financial/financial-web/src/core/api/ea-account/index.ts#L88-L98)：网络/5xx 时首页展示硬编码 mock 账号 861125 / 结余 45607.8，isMock 标记仅 1 处消费。金融产品信任红线。修复：降级仅限 dev，否则渲染错误态。【已落实 2026-11-25 web 39d09f2e：6 处 catch 降级加 import.meta.env.DEV 门禁】

### 中
- **W4.** 首页板块零错误态（HomePageSection:126-235），useHomeBlockData 的 error 返回值无人消费，失败整块静默消失 → 补错误分支+重试。【已落实 2026-11-26 web 43f0b839：showSectionError 分支（提示+重试按钮），与骨架屏互斥】
- **W5.** 30s 轮询不感知页面可见性（GoldTrendFeed:89-95 等，全库仅 1 处处理）→ 封装 useVisibilityAwareInterval。【已落实 2026-11-26 web 43f0b839：新增 useVisibilityAwareInterval（后台暂停/恢复可见立即刷新），接入 useAsyncData pollingInterval 全量轮询通道 + GoldTrendFeed】
- **W6.** 前端角色守卫基于可篡改 localStorage（guards/role.ts:19-33）→ 服务端已强校验为前提，前端以 /auth/info 实时为准。
- **W7.** 全局 onError 每个失败请求弹 toast 无合并（setupRequest.ts:37-40）→ 5s 去重。
- **W8.** 快讯/消息列表无虚拟化（NewsFlashList:17-29）→ 窗口化渲染。
- **W9.** resize 监听无节流（useBreakpoint:45-58）→ rAF 防抖。

### 低
- **W10.** WS registry 在 connect 抛错时条目泄漏（registry.ts:180-186）。
- **W11.** 错误文案硬编码中文破坏 i18n（request/core:129-134）。
- **W12.** mock 账号 861125、GoldTrendFeed fallback 品种写死（constants.ts:22）。
- **W13.** 图片 lazy 覆盖率 5/26。
- **W14.** mega-menu scroll 高频 getBoundingClientRect（useMegaMenuPanel.ts:66-67）。
- **W15.** MessageBubble 双端转义依赖（当前安全但脆弱）→ 组件化渲染 mention。

> 正面确认：401 单飞刷新+重放防循环、WS 引用计数+原子替换订阅+心跳探活、路由全懒加载、echarts 按需引入。

---

## 三、financial-admin（管理后台）

### 中
- **M1. HTTP 客户端无超时无取消** — [http/client.ts:34-54](file:///D:/Workspace/financial/financial-admin/src/shared/http/client.ts#L34-L54)：裸 fetch，慢请求 loading 卡死、15s 轮询下请求堆积重叠。注入 AbortSignal.timeout。【已落实 2026-11-25 admin 98bb703：未传 signal 默认 15s 超时 + 超时可读文案】
- **M2. 列表加载竞态：旧响应覆盖新响应** — useCrudPage.ts:63-73 无请求序号/abort。【已落实 2026-11-25 admin 98bb703：reload 请求序号，过期响应丢弃】
- **M3. MT5 两页完全无前端权限门禁** — ResourceSourcesView/StrategyConfigSheetsView 无 hasCapability 且路由未标 capability（nav.ts:203-209 对无标路由放行），URL 直达，门禁全靠后端。对齐 RefundView 补页面级判定。
- **M4. debug 推送接口进生产后台** — api/system/debug.ts:33-61（push-quote/push-headlines），可向 C 端推假行情假快讯，被 4 个生产页面引用。后端 capability 硬门禁 + 前端收敛。
- **M5. 代登令牌 URL query 传递** — users.ts:154-157 + window.open，进日志/历史。
- **M6. 登出不撤销服务端会话** — AdminLayout.vue:201-204 只清本地。
- **M7. CrudTable 全量拉取+前端分页** — CrudTable.vue:186-192，无虚拟化。
- **M8. 脚本上传无前端类型/大小校验** — ScriptUploadView.vue:95-134，accept 只是选择器过滤，文案 500KB 与实现不符。
- **M9. admin token 明文 localStorage** — stores/auth.ts:70。

### 低
- **M10.** 后台显式拒绝 MFA 账号（stores/auth.ts:77-79）。
- **M11.** 登录 redirect 未校验站内路径（LoginView.vue:82-83）。
- **M12.** 轮询不感知可见性（OpsView 15s / Dashboard 30s，有 onUnmounted 清理）。
- **M13.** Dashboard 3 个死链快捷入口（DashboardView.vue:115-119，路径与 router 不符）。
- **M14.** dev server 监听 0.0.0.0（vite.config.ts:19）。
- **M15.** 兜底路由公开，任意 URL 可确认"这是管理后台"（router/index.ts:344-348）。
- **M16.** 非 JSON 响应直接 res.json() 抛解析错误（client.ts:43）。
- **M17.** 前端预留 reveal_secrets 通道（datasource.ts:21-25）→ 删除。

> 正面确认：capability 路由守卫含前缀继承、危险操作均有二次确认、Pinia 无持久化插件、生产 sourcemap 关闭。

---

## 四、mt5-bridge（行情桥）

### 高
- **T1. MT5 IPC 四执行流三把锁互不相干（并发随机 -10004）** — [collector.py:1649,1742-1746,506](file:///D:/Workspace/financial/mt5-bridge-service/app/collector.py#L1649)：collect 线程锁内调用、`_build_publish_payloads` 锁外调 mt5.*（L578-590）、/rates 用独立 _rates_lock、verify 线程 mt5.login——MT5 包单 IPC 非线程安全。这是行情偶发缺失的第一嫌疑。修复：全部收敛到单把全局锁。【已落实 2026-11-25 api 315bfc7：_lock 改 RLock 为唯一 MT5 IPC 锁，payload 构建/verify/fetch_rates 全部纳入，47 测试过】
- **T2. 生产配置裸奔：0.0.0.0 + 空 api_token，缺失鉴权仅告警不阻断** — config.ini:33,38（"测完恢复 127.0.0.1"未兑现）；api.py:68-73 warning 后照常启动。局域网可无鉴权爆破 MT5 凭据（/accounts/verify）、注入账号、读全量数据。修复：非回环且无 token 时拒绝启动。【已落实 2026-11-25 api df9006d + winvm：config.ini 回环 + api_token 落地，RCC ea.api_token 同值，三态验证 health 200/无token 401/带token 200】
- **T3. WS 端点事件循环内跑同步重计算** — api.py:236：每秒 get_equity_history（最多 50 万点排序）+ drain_events（持锁），无 to_thread，多客户端叠加整桥假死。改 asyncio.to_thread。【已落实 2026-11-25 api b097399】
- **T4. /accounts/verify 同步 sleep 轮询最长 40s 占线程池** — api.py:115-121，数个并发即耗尽 anyio 线程池，全部端点排队。改异步提交+轮询接口。【已落实 2026-11-25 api b097399：改 async + asyncio.sleep，不占线程池 worker】

### 中
- **T5. mt5Initialized 判定失真** — collector.py:1767：只反映"曾成功"，终端掉线仍 true → 上游守护会持续拿"健康"。以 lastCollect 超阈值联动。
- **T6. PG 密码明文 config.ini** — config.ini:50；settings 已支持 env 优先但未启用（settings.py:277），另有 database_url 死属性。
- **T7. 轮询重复全量传输** — account-info 内嵌全量 deals（deals_lookback_days=0 从 2000 年起）；/rates 无 TTL 缓存。拆轻量 summary + 2-5s 缓存。【已落实 2026-11-26 api 2be1af3：桥 /account-info 与 /rates 加响应 TTL 缓存（默认 3s，response_cache_ttl_sec 可配），高频轮询不穿透 MT5 IPC/全量序列化（D8 同根受益）；轻量 /summary 端点已存在】
- **T8. 历史净值重建漏出入金** — collector.py:856-866：balance 类 deal 被排除未回放，有出入金账号曲线系统性偏移。【已落实 2026-11-26 api 68a3305：_seed_equity_history 回放全部成交（交易类 profit+swap+commission / balance 类 profit），基准从当前净值扣全部增量反推；6 例新单测，桥 53 过】
- **T9. K 线时间未做券商服务器时区换算** — collector.py:1749-1751：MT5 time 是服务器时区纪元（UTC+2/+3），上游按 UTC 解释偏移 2-3 小时；equity 采样用本地 time.time()，两套口径并存。【已落实 2026-11-26 api 68a3305：新增 _server_tz_offset/_mt5_time_to_utc（NY DST 自动推断 + server_tz_offset_hours 可配）；fetch_rates K 线 time 与净值回放点统一换算真实 UTC；API_DOC 已更新时间口径】
- **T10. config.ini 缺失静默用默认值/损坏时 SCM 假活** — settings.py:230-231 + win_service.py:187-189。（与部署链 B-F2 同根：config.ini 是关键机器资产）

### 低
- **T11.** psycopg2 无连接池，15s 周期反复建连（db.py:36-53，注释自相矛盾）→ SimpleConnectionPool。
- **T12.** 内存无淘汰：_snapshots 只增不删、_verify_queue 无上限、500k 点 × N 账号。
- **T13.** /health 无鉴权泄露 sessionLogin/server/内网 IP（collector.py:1766-1795）→ 最小化字段。
- **T14.** 涨跌幅两套口径并存（今日开盘价差存进 "last" 字段 vs 昨收差 change，L552-559 vs L586-591）。
- **T15.** 杂项：api.py:100-101 读私有属性回显账号列表；db.py:616-626 死代码 SQL；_win_process_running 返回 None 时自愈永不触发（L1090-1098）。

---

## 五、部署链与运行环境（winvm 宝塔，实战复盘）

### 已修复（2026-11-25 实证）
- **D-F1.** 宝塔建站覆盖 SPA index.html（640B 默认页），状态码仍 200 极具迷惑性 → 人工文档加 title 校验防线。
- **D-F2.** 部署清空删机器资产（run_bridge_task.bat + config\config.ini）→ deploy-win-baota.ps1 已加 `*.bat` 保留 + config.ini stash/restore。
- **D-F3.** pwsh `cmd1 & cmd2` 后台 Job 陷阱导致 mt5-bridge 静默部署两次、产生假备份。

### 未修复
- **D1.【高】** `-NoRestart` + 守护拉起 → 旧代码进程残留（schtasks"已在运行"拉不起新版本，今日实际发生）→ 部署默认停旧进程。【已落实 2026-11-25 deploy 10b3149：-NoRestart 时 user-session 组件停旧进程等守护拉起；service 形态维持跳过】
- **D2.【中】** Restart-Service 可能留孤儿 uvicorn 占 5001（wrapper 异常退出路径无防护）。【已落实 2026-11-25 deploy 10b3149：重启改 stop→Stop-PortOrphans→start】
- **D3.【中】** 健康门失败仅提示不自动回滚（deploy-win-baota.ps1:970-980）→ 失败自动 Invoke-ComponentRollback。【已落实 2026-11-25 deploy 10b3149：有备份自动回滚 latest，无备份明确报错】
- **D4.【中】** preflight 不覆盖 user-session 组件（计划任务/bat/config.ini 端口一致性零校验）。【已落实 2026-11-25 deploy 10b3149：preflight 增加计划任务存在性/启动脚本 *.bat/config.ini 端口一致性校验】
- **D5.【中】** Swagger /docs 对公网暴露（运行时实测 200）→ 生产关 docs_url。【已落实 2026-11-25 api 205d091：is_production 时 docs/redoc/openapi 全关，单测 2 例；随 P0 部署生效】
- **D6.【低】** Redis 无密码（6379 内网裸奔）。
- **D7.【低】** 凭据散布多文件（PG 密码在 env/config.ini/面板三处），文档未脱敏。
- **D8.【低】** 行情 overview 外部实测 1.7s：api 端 fetch_candles 实时过桥无缓存（与 T7 同根，修一处全链路受益）。

---

## 六、架构与文件结构

### 后端（financial-api + mt5-bridge）

**架构级（跨模块影响）**
- **X1. `fin_mt5_*` 表三个 DDL 来源，schema 无单一事实源**：bridge 的 init_tables.sql + db.py::ensure_tables()（IF NOT EXISTS 永不追赶）、api 的 alembic 4 个迁移、mt5_collector._ensure_ingest_tables() 测试补齐——T9 时区口径漂移的结构根源。收敛为 bridge DDL 唯一 owner + alembic 只读校验。【已落实 2026-11-26 api bfab093：桥 db.py::_TABLES_DDL_TEMPLATE 为 DDL 唯一 owner（init_tables.sql 镜像 + test_ddl_parity 门禁）；alembic b5c6d7e8f9a0 只读校验九表存在；api _ensure_ingest_tables 每进程一次 to_regclass 探测 + 生产缺表 fail-fast + 非生产幂等补齐】
- **X2. 桥↔api 契约四条通道四种口径**：HTTP 靠手写 API_DOC.md、Redis 行情手拼 camelCase dict 单边校验、DB 表共享 init_tables.sql、ingest 又是 api 侧独立 IngestPayload。无共享包，字段改动人肉同步 4 处 → 抽 `contracts` 共享 pydantic 包（api 已有 generated.py 先例）。【已落实 2026-11-26 api 9125801：新增仓库根 contracts/ 共享包（纯 pydantic 零 app 依赖）——QuoteTick（Redis 行情，api QuoteSnapshot 改继承）/ IngestPayload（ingest，api schemas 改 re-export）/ RatesResponse（/rates 响应，api 裸 dict 解析改 typed）三通道收敛；桥侧 _build_publish_payloads/_build_ingest_payload/get_rates 改构造契约模型，打包经 deploy extra_source 搭车进 package/contracts；/accounts/verify 响应字段少且带错误码映射，保留 API_DOC 文档化；api 775 / 桥 60 测试过；DB 通道已由 X1 收敛】
- **X3. `app/crawler` 是 domains 体系外的 9090 行"影子域"**（占 614 个 py 文件 1/4 体量），两套组织范式并存 → 收编为 domains/crawler 或文档固化豁免。【已落实 2026-11-27 api 97f354c：裁定文档固化豁免——architecture.md 新增 "Deliberate Architectural Exemptions" 节，约定 crawler/worker/realtime 同属域外基础设施层，新采集源放 crawler/ 不放 domains/】
- **X4. repository 层夹生**：仅 content/engagement/market/news/trade 走 repositories/（18 域引用），resources/system 直接持 Session 写 ORM，system/app_config 甚至 router 直写 delete → 明确"可选"或补齐。【已落实 2026-11-27 api 97f354c：裁定 repository 为可选模式并固化 architecture.md——简单 CRUD 就地写在 service，查询复杂到需复用/测试隔离才抽 repositories/，不回填不强制迁移】
- **X5. content↔system 双向依赖成环**：home 聚合域反向 import 5+ 域，auth/local→member/agents 靠函数内延迟 import 绕开 → 聚合类跨域 schema 下沉 app/shared。【已落实 2026-11-27 api 97f354c：HomeAdBanner 下沉 app/shared/schemas/home.py（content.ads 改依赖 shared，system.home 保留 re-export 兼容），断开 content.ads ↔ system.home 环；auth→member 函数级延迟 import 与 app_config→ads 属已接受环解扣手段，同节固化约定；unit 799 过 + winvm 实机 /api/home/dashboard 200】

**结构级**
- **X6.** resources/service.py 1003 行全仓最大 + 域根平铺，与 market/content 子包组织相反 → 拆子包。【已落实 2026-11-27 api 97f354c：service.py（1129 行）拆子包 service/（catalog/admin_crud/admin_files/admin_pricing/admin_queries/favorites/strategies + _common 跨节 helper），__init__ 全量 re-export 零调用方改动（11 处测试 patch 目标重定向到真实子模块命名空间）；顺手修复 test_routes_registered 过期断言（strategy-configs/batch）；unit 935 全过 + winvm 部署实测 /api/resources 200】
- **X7.** 桥 collector.py 1609 行 59 方法巨石（采集/验证/落库/发布全在一个类），db.py 631 行裸 SQL → 拆 verify-queue/persist/publish 模块。【collector 部分已落实 2026-11-27 api 7729a7f：collector.py 1895→1182 行，拆 VerifyQueueMixin（collector_verify）/MarketDataMixin（collector_market）/EquityEventsMixin（collector_equity）/PersistMixin（collector_persist），方法体逐字迁移；_collect_account 因 AccountSnapshot 运行时构造 + 测试 patch("app.collector.mt5") 依赖留在宿主；桥 60 测试过 + winvm 部署实测 health 200 / heartbeat accounts=2。db.py 裸 SQL 收敛留待后续批次】
- **X8.** alembic upgrade_head 失败仅 warning 继续启动（db/migrate.py）——迁移失败 schema 静默落后 → prod fail-fast。【已落实 2026-11-25 api 91436dd：生产迁移失败抛出阻止启动（配合 D3 健康门自动回滚），非生产保持容错；3 例单测】
- **X9.** core/shared 边界含糊（两处 i18n 命名不可区分）；runtime 配置三层叠加 + bridge 裸 SQL 直读 fin_data_source_configs（60s 缓存不一致窗口）。

**卫生**
- **X10.【立即处理】mt5-bridge-service 不在 git 管控下**（not a git repository），config.ini.bak×3、accounts.json.bak 散落仓库目录 → 立即建库 + 清理 bak。【已落实 2026-11-25 api bf97002：并入 financial-api 仓库 mt5-bridge/ 子目录（32 文件），密钥/日志/bak 双 .gitignore 防线，bak 清除，原目录归档，deploy project.toml source_path 已改指新位置】
- **X11.** api 153 个测试文件+CI 完整，但桥仅 9 个 ad-hoc 脚本无 CI；mypy 13 个 overrides 把行情核心链路豁免——类型检查对最关键代码失效。
- **X12.** 孤儿目录：api/scripts_tmp/（10 个临时脚本）、web/scripts_tmp/（4 个诊断 cjs）、logs/、.worktrees/ 混仓库根。【已落实 2026-11-27 api 19e523e + web a5151b01：scripts_tmp 出库（可复用的 e2e_verify_v544.cjs / seed_deploy_incremental.py 迁 deploy/scripts/financial-verify/，deploy 76c2681），两端 /scripts_tmp 入 ignore；web .gitignore UTF-16 乱码行修复，web 空 scripts_tmp/logs/.worktrees 删除并入 ignore；api 空 logs/.worktrees 删除】

### 前端（financial-web + financial-admin）

**架构级**
- **X13. 两工程分层完全异构**：web 六层（app/core/modules/shell/domains/shared）+ AGENTS.md + audit-boundaries.mjs 强制；admin 传统四层无 lint/无 CI/无测试门禁——"重工程化"与"轻量快跑"断层。【已落实 2026-11-25 admin a08d8d8：ESLint flat config（基线对齐 web）+ lint 脚本 + 310 存量错误清零 + GitHub Actions CI + AGENTS.md；eslint 0 错误 / vue-tsc / vitest 129 过】
- **X14. API schema 34k 行字节级重复 + 隐性跨工程依赖**：`src/types/api/generated/schema.d.ts` 两边 MD5 相同（34247 行）；admin package.json 直接执行 `node ../financial-web/scripts/api-field-audit.mjs` → 把 web 的 packages/contracts 提为共享 workspace 包。【已落实 2026-11-25 web 7ab38b50 + admin d1942d1：audit 脚本迁入 web/packages/contracts/scripts/（resolveWebRoot/resolveAdminRoot），admin 改调同一实体；admin api-sync --check 增 schema.d.ts 字节级比对防漂移】
- **X15. i18n 能力不对等**：web 完整 locales + "No hardcoded copy" 强制；admin 无 vue-i18n——若 C 端多语言则后台永远中文，需显式决策。

**结构级**
- **X16.** admin 路由单文件 368 行守卫内联无测试（web 已拆 modules+guards+测试）→ 照 web 模式拆，成本约半天。【已落实 2026-11-27 admin 43a7c5b：路由表拆 routes.ts、守卫拆 guards.ts（setupRouterGuards），新增 guards.spec.ts 7 例（无 token 重定向/公开路由/restoreSession 成败/capability 拦截/最长前缀继承）；vitest 136 过】
- **X17.** Pinia 两极分化：web 15 store 分层+审计脚本；admin 仅 1 store，741 行 UsersView 承载全部状态 → admin 重页面抽 composable。【部分此前已落实（6 个 composables）；2026-11-27 admin 43a7c5b：UsersView 778 行 → 253 行，对话框/抽屉拆 5 子组件（UserFormDialog/UserDisableDialog/TempPasswordDialog/UserDetailDrawer/RolePermDialog，各自内聚 composable + defineExpose），纯展示辅助下沉 userTag.ts；实机回归 7/7 PASS】
- **X18.** 样式：web 自建 SCSS token 7 层+审计脚本；admin 仅 2 个 css 直用 element-plus → admin 至少引用 web token 子集。【已落实 2026-11-27 admin 43a7c5b：新增 styles/tokens.css（字号/行高/间距/圆角/阴影/浅色语义色，镜像 web primitives + _default 浅色主题，头部注明手工同步约定），main.ts 先于 global.css 引入，admin-common.css 字号/间距/圆角全部换 token；--el-* 语义色维持】
- **X19.** 巨石组件仅 2 个：EaAccountSummaryFeed 1104 行、UsersView 741 行 → 拆子组件/抽 composable，其余无需处理。【admin 侧 UsersView 已拆（43a7c5b，见 X17）；web 侧 EaAccountSummaryFeed 早前已抽 useEaDeals/useEaSummaryStats/useEaDealChart/chart.ts + 2 测试，index.vue 本体（~1235 行）拆分属 C 端生产行情组件，留待单独批次（不在 admin 重构范围）】
- **X20. H5/PC 共存策略判定：单代码库响应式合理，不拆 H5 工程**（拆分将复制 shell/core 40+ 模块，成本远大于收益）。

> 正面确认：两工程 any 密度极低（12/9 处）、路由全懒加载、web 的三个边界审计脚本体系是显著亮点。**monorepo 判定：仅契约层合并（contracts 包），业务代码不合并**——受众、UI 配置、迭代节奏不同。

---

## 七、修复路线建议

**P0（安全红线 + 架构止血，1-2 天内）**
1. A1 EA 账号越权（一行归属校验前置）
2. T2 桥 0.0.0.0+无 token 拒绝启动 + config.ini 恢复 127.0.0.1+token
3. A2 MT5 密码加密落库（配合 T6 密码进 env）
4. W3 mock 降级仅 dev（金融数据信任红线）
5. D5 /docs 生产关闭
6. X10 mt5-bridge 立即建 git 库（当前源码无版本管控，等于裸奔）

**P1（稳定性，本周）**
7. T1 桥锁统一（行情偶发缺失第一嫌疑）
8. T3/T4 桥线程池与事件循环阻塞
9. A5/A6 JWT aud + WS 会话吊销
10. M1/M2 admin 请求超时+竞态
11. D1-D4 部署链四件套（停旧进程/自动回滚/preflight 扩展）
12. X8 alembic 迁移失败 prod fail-fast

**P2（正确性+体验，下迭代）**
13. T8/T9 历史净值出入金 + K 线时区（行情正确性）
14. A3/T7 行情缓存与索引（1.7s → <200ms）
15. W1/W2 token 存储与传输
16. W4/W5 错误态+可见性轮询
17. X1/X2 契约层收敛（contracts 共享包 + DDL 单一 owner）——架构债最大头
18. X13/X14 admin 补 lint/CI + schema 去重（随 X17 一起）
19. 其余中低项按模块排期

**回归防线（每次发版/宝塔升级必跑）**
- 首页 title=深量科技；桥 health mt5Initialized=true 且端口 9199；bat/config.ini 在位；`-Status` 双服务 RUNNING；守护任务安全选项未重置。
