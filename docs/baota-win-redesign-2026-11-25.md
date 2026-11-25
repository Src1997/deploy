# winvm / Windows Server 统一宝塔化 redesign（设计评审稿）

> 版本 v1（2026-11-25）。**本文档先于代码**：仅出方案，不写任何通道实现/脚本改动。
> 背景：用户 2026-11-25 拍板「winvm 也用宝塔，后续 Windows Server 也统一宝塔」，
> 并要求文档**同时保留两种 MT5 落地方案、互为备用**：
> ① 宝塔计划任务指定「登录用户身份 + 最高权限」；
> ② MT5 桥保留 user-session 特殊通道。
> 目标：把 winvm 现役的 NSSM + 裸 Nginx 链路，逐步收编到宝塔面板统一运维；
> `baota-win` 作为与现有 native/baota/docker/win 并列的第五通道，遵循同一份动词契约。

---

## 0. 一句话结论

**宝塔能管 winvm 的绝大多数东西（Nginx 站点、前端 dist、普通 Python 后端、文件、数据库），
唯一不能按默认姿势管的是 MT5 桥**——因为宝塔 Windows 版计划任务默认以
SYSTEM/LocalSystem 身份、在 Session 0 运行，而 MetaTrader5 的 IPC 必须要交互式用户会话，
否则 terminal↔python 通道超时（本项目 `win-channel-design-2026-11-13.md` D9 实证）。
所以 MT5 桥给两条路：**宝塔里用「登录用户身份 + 最高权限」的计划任务拉起（方案 A）**，
或**保留现有 user-session 特殊通道、宝塔不管它只做备用（方案 B）**。两条互为备份。

---

## 1. 事实底座（为什么这样设计）

### 1.1 宝塔 Windows 版能力边界（2026-11-25 联网核实）

| 能力 | 宝塔 Windows 版 | 对本项目 |
|---|---|---|
| 网站 / Nginx / 反代 / SSL | ✅ 支持（v8.x，Server 2012–2025） | 可收编 winvm 裸 Nginx 的 80 站点、`/api/` 反代、`/admin/` alias |
| 前端 dist 托管 | ✅ 网站根目录 + 文件管理器 | 可收编 web/admin dist |
| 普通 Python 后端 | ✅ Python 项目管理器 / 计划任务（SHELL） | 可收编 financial-api（5001）；不依赖交互桌面的纯 HTTP 服务 |
| 数据库 | ✅ MySQL/MariaDB/SQLServer 管理 | PG 可继续 NSSM（宝塔对 PG 管理弱），或纳入统一监控 |
| 计划任务 | ⚠️ 是 Windows 任务计划程序（schtasks）的封装，功能不如 Linux 完善 | 默认 SYSTEM/LocalSystem 身份 → MT5 IPC 死；**必须显式改运行身份** |
| 进程守护 | 宝塔 supervisor / 计划任务 | 普通服务可用；MT5 类不可用默认形态 |

> 结论：宝塔 Win 版「管站点、管文件、管普通服务」没问题；「管 MT5」卡在**进程身份与会话**，
> 不是宝塔本身不行。

### 1.2 本项目实证（不可推翻的约束）

- `win-channel-design-2026-11-13.md` **D9**：MetaTrader5 IPC 需交互式桌面会话；
  NSSM 服务 / Session 0 / LocalSystem 下 terminal↔python 超时；用户会话前台运行是官方推荐。
- `svc_entry.py` 头注：现役 bridge 已弃用 pywin32 服务形态。
- 8.2 坑③：ssh 拉起的进程随会话关闭被杀 → 常驻进程必须 NSSM 服务或计划任务。
- 8.2 坑④：nssm stderr 假告警（PS EAP=Stop 误中断）——宝塔链路里不再碰 nssm，此坑自然规避。
- 8.3：现役单机布局 `C:\opt\{pgsql,nssm,redis,nginx}` + `C:\wwwroot\project\...`。

⇒ redesign 的唯一硬约束：**MT5 桥进程必须在交互式登录用户会话中、以登录用户身份运行**。
其余组件按宝塔常规能力收编即可。

---

## 2. 目标架构（baota-win 通道）

### 2.1 通道定位

`baota-win` = 「宝塔 Windows 面板」作为 Windows 目标机的运行载体，与现有通道并列：

```
DEPLOY_CHANNEL = native | baota | docker | win | baota-win
```

- 与 `win` 通道（deploy-win.ps1，NSSM + 裸 Nginx）的关系：
  `baota-win` 是它的**宝塔化演进版**，同样走「目标机自包含执行」哲学，
  但进程托管/站点/路由改为调宝塔面板 API 或宝塔能力，而非 NSSM/裸 Nginx。
- 遵循 CHANNEL-CONTRACT 全部 16 动词；「同机单通道」铁律不变（winvm 从 `win` 迁到 `baota-win`
  需先清场 NSSM/裸 Nginx，见 §5）。

### 2.2 组件归属总表（winvm 现状 → 宝塔化目标）

| 组件 | 现役（win 通道） | 宝塔化目标 | MT5 约束 | 方案 |
|---|---|---|---|---|
| Nginx 80 站点 + `/api` 反代 + `/admin` alias | 裸 nginx + NSSM(nginx-quant) | 宝塔「网站」统一管理 | 无 | 宝塔常规 |
| financial-web dist | 裸目录 `financial-web/dist` | 宝塔网站根目录 | 无 | 宝塔常规 |
| financial-admin dist | 裸目录 `financial-admin/dist` | 宝塔网站/子目录 | 无 | 宝塔常规 |
| financial-api（5001） | NSSM 服务 | 宝塔 Python 项目管理器 / 计划任务守护 | 无 | 宝塔常规 |
| PostgreSQL（pg-quant） | NSSM + NetworkService | 维持 NSSM（宝塔对 PG 管理弱）或纳入监控 | 无 | 保留 NSSM |
| Redis（redis-quant） | NSSM | 宝塔 Redis 管理（可选） | 无 | 宝塔常规或保留 |
| **mt5-bridge（9199）** | schtasks + user-session | **方案 A / B 二选一（见 §3）** | **★必须交互会话** | 特殊 |

---

## 3. ★MT5 桥双方案（用户拍板：同时保留、互为备用）

两条方案都是**已验证或强依据**的落地方式，文档同时保留；上线选一条为主、另一条为备，
切换只需停一个、起另一个（端口同为 9199，注意互斥）。

### 3.1 方案 A —— 宝塔计划任务「登录用户身份 + 最高权限」

**原理**：宝塔 Windows 版计划任务底层是 schtasks 封装。默认以 SYSTEM/LocalSystem 运行（Session 0）
→ MT5 IPC 死。解决办法是在宝塔创建计划任务后，**到 Windows 任务计划程序里把该任务的安全选项
改成「登录用户身份」**，这是唯一能拿到交互式会话的路径。

**落地步骤**：

1. 宝塔面板 → 计划任务 → 新增 SHELL 计划任务，执行一个 `.bat`：
   ```bat
   @echo off
   cd /d C:\wwwroot\project\mt5-bridge-service
   C:\Python313\python.exe -m app.main >> C:\wwwroot\project\mt5-bridge-service\logs\bridge.out.log 2>&1
   ```
   - 触发器按需（开机启动 / 每 N 分钟守护检测进程是否在）。
   - 脚本必须 CRLF、绝对路径调解释器（8.2 坑⑦⑨）。
2. **关键**：打开 Windows「任务计划程序」→ 找到宝塔创建的任务（名带 `BT-`/`bt`）→
   属性 → 常规 → 安全选项：
   - 选 **「使用以下用户账户」= 登录的那个管理员账户**（如 `Administrator`）；
   - ✅ **勾选「使用最高权限运行」**；
   - ❌ **不勾「不管用户是否登录都要运行」** ← 勾了就回 Session 0，MT5 IPC 必死。
3. 该登录用户需保持登录状态（服务器重启后自动登录，或运维保证登录会话在）。
4. 守护语义：计划任务周期执行 `.bat` 前先探测 9199，若已在线则退出，仅掉线时拉起。

**优点**：统一在宝塔「计划任务」界面可见/可改，符合用户「都走宝塔」的诉求。
**风险/注意**：
- 宝塔面板升级可能重置任务安全选项 → 升级后需复核（写进回归清单 §6）。
- 依赖登录会话持续存在；服务器重启需自动登录或人工登录。
- Windows 版宝塔计划任务功能不如 Linux 完善，若面板侧改不动，退回方案 B。

### 3.2 方案 B —— MT5 桥保留 user-session 特殊通道（宝塔不管，备用）

**原理**：沿用现役已验证的 `process.hosting=user-session` 形态（win-channel-design D9），
MT5 桥不交给宝塔守护，由 Windows 自身在交互会话里拉起，宝塔只做「可见但不接管」。

**落地步骤**（现役做法，保持不变）：

1. 交互会话里 `Start-Process -WindowStyle Hidden` 启动 bridge，写 PID 文件
   `logs/<svc>.pid`，stdout/stderr 重定向 `logs/<svc>.out.log`。
2. 自启用 `shell:startup` 快捷方式（登录即拉起）或 schtasks 指定登录用户。
3. 停止 = `Stop-Process`（按 PID 文件）；重启 = 先停后起。
4. RCC `ea.api_base_url` 指向 `http://127.0.0.1:9199` 不变。

**优点**：久经实战、不依赖宝塔计划任务稳定性、与宝塔解耦。
**风险/注意**：与「全部走宝塔」的诉求略有偏离——定位为**方案 A 失效时的备用/回退通道**。

### 3.3 双方案互斥与切换

- 同一时刻只允许一条通道持有 9199（端口互斥），避免双实例抢 MT5 终端 IPC。
- 切换 SOP：停当前通道进程 → 确认 9199 释放 → 起目标通道 → `curl 127.0.0.1:9199/health` + `/rates` 验证。
- 默认策略：**A 为主、B 为备**；A 出现「升级后任务身份被重置 / 登录会话丢失 / IPC 超时」时切 B。

---

## 4. baota-win 通道设计（与非 MT5 部分对齐契约）

### 4.1 16 动词映射（相对 win 通道的差异）

| 动词 | baota-win 实现 | 与 win 通道差异 |
|---|---|---|
| `channel_name` | echo `baota-win（宝塔面板 + MT5 双方案）` | 标识变更 |
| `channel_supported_kinds` | echo `python frontend` | 同 win |
| `channel_wants_host_venv` | echo `1` | 同 win |
| `channel_routing_sync` | 调宝塔建站/反代 API（网站=组件 id，反代 `/api/`→5001） | 由裸 Nginx 配置模板改为面板 API |
| `channel_frontend_prepare/preserve/restore/finalize` | 宝塔网站根目录 + `.user.ini` 保留（对齐 baota Linux） | 复用 baota 语义 |
| `channel_python_install` | 普通 Python 后端：宝塔 Python 项目管理器/计划任务；**MT5 组件按 §3 分流** | 核心差异：进程托管分叉 |
| `channel_python_restart` | 普通服务走宝塔 restart；MT5 走 §3.3 切换 SOP | 核心差异 |
| `channel_service_running` | 宝塔项目状态 + health_url 探活 | 同契约 |
| `channel_status/logs` | 宝塔项目状态/日志聚合 + MT5 特殊通道独立探测 | 补充 MT5 通道探测 |

> 契约细节以 `CHANNEL-CONTRACT.md` 为 SSOT；baota-win 不新增动词、不改语义，
> 只替换「谁来托管进程/站点」这一层（呼应契约 §1 所有权彻底原则）。

### 4.2 部署主链路（目标机自包含）

```
0. 清场（仅首次从 win 迁移）：停 NSSM 服务、导出裸 nginx.conf 备份、确认端口腾空
1. 环境装载：deploy.env.server-baota-win（DEPLOY_CHANNEL=baota-win）
2. preflight：宝塔面板 API 可达 / 目标站点权限 / 登录用户身份确认（MT5 用）
3. 宝塔建站：网站=组件 id，root 指向 wwwroot 对应 dist，反代 /api/ → 5001
4. 前端：dist 平铺到网站根目录（保留 .user.ini）
5. 后端：普通服务 → 宝塔 Python 项目；MT5 → §3 方案 A/B 分流
6. 数据库/Redis：维持现状或纳入宝塔（PG 建议继续 NSSM）
7. 健康门：health_url ×3 + MT5 /rates 探测，失败计败
8. 审计：deploy.log 记录包文件名 + 通道 + MT5 方案标识
```

### 4.3 配置面同步（改一处同步 N 处）

| 文件 | 改动 |
|---|---|
| `project-configs/CHANNEL-CONTRACT.md` | §1 通道枚举加 `baota-win`；§4 翻译表加列；§5 实现现状加行 |
| `scripts/channels/registry.sh` | `DEPLOY_CHANNEL` 合法值加 `baota-win`（误配引导） |
| `deploy.env.server-baota-win` | 新增（宝塔面板地址/密钥、登录用户、MT5 方案选择键） |
| `tests/run-all.sh` 动词审计 | 扫描 baota-win 实现（若走 PowerShell 则同 win 分支；若走 baota-api.py 则纳入） |
| 本文档 | 定稿后转实现任务 |

---

## 5. 迁移步骤（winvm → baota-win）

分阶段、可回退，每阶段独立验收：

| 阶段 | 内容 | 回退点 |
|---|---|---|
| M0 | winvm 安装宝塔 Windows 版（v8.x，Server 2019/2022）；确认面板可登录 | 卸载宝塔，NSSM 链路原样 |
| M1 | 裸 Nginx 站点收编到宝塔「网站」：先建站指向现有 dist，验证 80 页面与 `/api/` 反代 | 停宝塔站点，恢复 nginx-quant |
| M2 | web/admin dist 迁到宝塔网站根目录（保留 `.user.ini`），hash 比对 | 切回原 dist 目录 |
| M3 | financial-api 迁到宝塔 Python 项目（5001），health 验证 | 停宝塔项目，nssm start financial-api |
| M4 | **MT5 桥切方案 A**（宝塔计划任务+登录用户身份）；失败即切方案 B（user-session） | A↔B 按 §3.3 SOP 切换 |
| M5 | PG/Redis 视情况纳入；通道标识切 `baota-win`，全量三验 | 保留 NSSM 服务不动 |

---

## 6. 回归验证清单（每阶段/每次宝塔升级后必跑）

1. **版本三验**：ex5 字节数/新字段/新日志行（MT5 侧）；web/admin assets hash 比对（前端）。
2. **前端**：PC 有账户金额、无走势卡；H5 有走势卡、四品种切换价格刷新、登录弹框手机形态全屏。
3. **API**：`/api/health` = ok；`/api/home/blocks?device=mobile` 有 gold-trend 无 ea-account-summary；
   desktop 相反。
4. **MT5（重点）**：
   - `curl 127.0.0.1:9199/health` 通；
   - `/rates?symbol=XAUUSD&timeframe=H1&count=3` 返回 K 线（证明 IPC 有交互会话）；
   - **宝塔升级后**：复查计划任务安全选项仍是「登录用户 + 最高权限 + 未勾不管登录」（方案 A）。
5. **站点**：80 首页、/admin/、/api/ 反代 200；SSL（如启用）证书有效。
6. **双方案互斥**：确认 9199 同一时刻只有一个实例。

---

## 7. 风险登记

| # | 风险 | 处置 |
|---|---|---|
| R1 | 宝塔 Win 版计划任务升级后安全选项被重置 → MT5 IPC 死 | 回归清单 §6.4 强制复核；准备切方案 B |
| R2 | 登录会话丢失（重启/注销）→ 方案 A 失效 | 服务器设自动登录或保证运维登录；否则用方案 B |
| R3 | 宝塔 Win 版功能不如 Linux，Python 项目管理器能力有限 | preflight 探测；不满足则普通服务保留计划任务守护 |
| R4 | PG 纳入宝塔管理弱 | 建议 PG 继续 NSSM，仅纳入监控，不强行收编 |
| R5 | 从 win 迁移期端口/进程冲突 | M0 清场 + 每阶段独立回退点 |
| R6 | 双方案同时在线抢 MT5 终端 | §3.3 互斥 SOP，健康门检查单实例 |

---

## 8. 非目标（本次设计明确不做）

- 本次**不写任何实现代码/脚本**（用户要求「先出文档」）。
- 不改现役 win 通道（deploy-win.ps1）行为；baota-win 是并列新通道，迁移按 §5 分期。
- 不强行把 PG 收编进宝塔（管理弱，保留 NSSM）。
- 不涉及 Linux 侧 native/baota/docker 三通道的任何改动。

---

## 9. 待用户拍板项

1. 主方案选 A（宝塔计划任务+登录用户身份）还是 B（user-session 备用）？本文档默认 **A 主 B 备**。
2. 是否接受服务器保持登录会话（方案 A 前提）？若不接受，直接 B 主。
3. PG/Redis 是否纳入宝塔，还是维持 NSSM（本文档建议维持）？
4. 迁移窗口与是否保留现役 win 通道作为长期回退（本文档建议保留）。
