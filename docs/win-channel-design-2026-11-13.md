# win 通道设计 — 部署工具箱跨平台扩展（Linux + Windows）

> 版本 v1（设计评审稿，2026-11-13）。**本文档先于代码**，定稿前不写任何通道实现。
> 背景：MetaTrader5 Python 包仅 Windows 可用 ⇒ `mt5-bridge-service`、`ea-lab-api`
> 等 MT5 生态组件只能落在 Windows 目标机；现有工具箱服务器侧为纯 Linux 链路。
> 目标：新增 **win 通道**，使「部署 = kind × channel」矩阵扩展到 Windows，
> 不破坏现有 native/baota/docker 三通道的任何行为。

---

## 1. 现状审查结论（2026-11-13 全量复核）

### 1.1 现有执行拓扑（Linux 侧）

```
本地 Windows（构建机）                    目标机（Linux）
────────────────────────                ──────────────────────────────
build.ps1 / pack.ps1                    /www/wwwroot/project/uploads/dist/
  → 打包 tar.gz           ── ssh 上传 →    ├── deploy.sh          ← 主入口（bash）
  → dist/ 整目录同步                       ├── core/              ← 装载/调度/备份
                                          ├── kinds/             ← kind 部署流程
                                          └── channels/          ← 通道 16 动词
                                          bash deploy.sh <id> --target=... --yes
```

哲学：**部署逻辑随 dist 走、目标机自包含执行**（deploy.log 审计、flock 并发锁、
--history 全部在目标机闭环）。

### 1.2 Linux 假设渗透点清单（win 通道必须逐一解决的）

| # | 环节 | 现状 | Windows 影 |
|---|---|---|---|
| L1 | 服务器端入口 | `deploy.sh`（bash + core/ + kinds/ + channels/） | 目标机无 bash 依赖 ⇒ 需 PowerShell 平行入口 |
| L2 | 通道加载 | `channels/registry.sh` source bash 通道文件 + fail-fast 断言 | bash 在目标机不存在 ⇒ 断言移入 PowerShell 层 |
| L3 | 进程托管 | systemd / 宝塔 supervisor / docker compose | NSSM（Windows 服务事实标准） |
| L4 | python kind 部署钩子 | `deploy-python.sh`：venv→bin/、pip、.env sed 渲染 | venv→Scripts\、渲染改 PowerShell -replace |
| L5 | 路由层 | nginx / 宝塔站点 | 一期**不做**（MT5 组件均为纯后端 API，路由在 Linux 生产机） |
| L6 | 并发锁 | flock + /tmp/deploy.lock | lock 文件 + 重试等待（等价语义） |
| L7 | 解压 | tar xzf（GNU tar） | Win10+ 自带 bsdtar，`tar -xzf` 直接可用 ✅ |
| L8 | 健康检查 | curl | Win10+ 自带 curl.exe ✅（或 Invoke-WebRequest） |
| L9 | 清空保留名单 | .env/.venv/logs/data（find 排除） | Copy-Item/Remove-Item 排除等价实现 |
| L10 | 备份/回滚 | 时间戳目录 + MAX_BACKUPS=5 | Copy-Item 语义一致，回滚=反向复制 |
| L11 | 打包侧 | pack.ps1 产 tar.gz——**已是 Windows** | 无需改动 ✅ |

> L7/L8/L11 是利好：打包格式、探活工具、构建机环境三个环节零成本跨平台。

### 1.3 不可破坏的现有不变量

- CHANNEL-CONTRACT 16 动词 + registry fail-fast（三通道不动一行）
- TOML 意图模型（routes/process/companions，零通道字眼）
- servers 单源化（deploy.env.server-* 为唯一环境来源）
- 同机单通道；密码只进 deploy.env*；deploy_path 唯一；.env 全排除仅 include_env 放行
- kind 双端契约（pack.ps1 ↔ deploy-kinds.sh 字段一致）

---

## 2. 关键架构决策（D1–D8）

### D1 执行拓扑：Windows 侧「平行入口」而非「通道插件」

| 选项 | 描述 | 结论 |
|---|---|---|
| A. 平行入口 | 目标机执行 `deploy-win.ps1`（PowerShell 三合一：core+kinds+win 通道），与 deploy.sh 对称 | ✅ **采纳** |
| B. bash 通道插件 | 仿三通道在 channels/ 下写 win.sh | ❌ 目标机无 bash，整个运行时前提不成立 |
| C. 本地 push 模式 | 部署逻辑在构建机，ssh 逐条下发 | ❌ 破坏「目标机自包含」哲学；审计/锁/回滚全外置，与 --history/backup 体系割裂 |

**核心语义**：`deploy-win.ps1` 在 Windows 目标机上等价于 Linux 侧的
`deploy.sh + core/ + kinds/python + channels/win`。16 动词以**同名 PowerShell 函数**
实现（`channel_python_install` 等，PowerShell 允许下划线函数名），入口处执行与
registry.sh 等价的动词断言（同一份 `_CHANNEL_REQUIRED_VERBS` 清单，缺失 fail-fast）。
契约是跨实现的：CHANNEL-CONTRACT.md 是 SSOT，bash 三通道与 ps1 win 通道都向它对齐。

### D2 目标机选择：OpenSSH Server（不引入 WinRM）

Windows 10 1809+ / Server 2019+ 内置可选功能 OpenSSH Server，启用后：
- 上传：`scp`（Win 目标机默认启用 sftp-server；本地 scp 记忆坑「读不到 ~/.ssh/config」
  用 `-i <密钥> -P <端口>` 显式指定绕过）或 `ssh <win> "cat > 目标"` 等价管道——**列 P2 真机验证项**
- 远程执行：`ssh <win> "powershell -NoProfile -File D:\...\deploy-win.ps1 <id> -Yes"`
- 默认 shell 可设为 powershell（`ssh <win>` 体验与 Linux 侧一致）

备选 WinRM（pywinrm）被否：新增协议栈、凭据体系独立、与现有 ssh 别名体系不统一。

### D3 本机模式：目标=构建机自身时免 ssh

bridge 现状就跑在构建机本机（D:\Novquant Markets MT5 Terminal 同机）。
`deploy-win.ps1 -Local` 直接在本机执行打包内容安装（或免打包直指源目录），
ssh/上传全免。**bridge 的首个试点就走本机模式**，远程 OpenSSH 验证放 P2。

### D4 一期范围收敛（防贪大）

| 项 | 一期 | 说明 |
|---|---|---|
| kind | **python only** | `channel_supported_kinds` = `python`；其余 kind 报清晰错误 |
| 路由层 | **无** | bridge(127.0.0.1:9099)/ea-lab-api 均纯后端；对外路由本来就在 Linux 生产机收口。二期如需再评估 Nginx for Windows / IIS 反代 |
| 进程托管 | **NSSM** | 服务名=组件 id（与 baota 项目名=组件 id 对称）；伴随进程=同名前缀多服务 |
| 打包 | tar.gz 原样 | Win10 bsdtar 直接解 |
| 16 动词 | **全实现** | 契约要求 fail-fast；`routing_sync`/`frontend_*` 以「明确不支持」语义占位（报错或 no-op，不是缺席） |

### D5 TOML 意图扩展：新增可选键 `cmd_win`

意图模型零通道字眼的原则下，`process.cmd` 现有值天然带 POSIX 色彩
（如 `venv/bin/gunicorn`）。win 通道翻译表：

| TOML 意图 | win 通道落地 |
|---|---|
| `process(port, cmd, cmd_win?)` | NSSM 服务：AppDirectory=deploy_path，AppParameters=`cmd_win`（缺省回退 `cmd`，但 venv/bin/ 形态在 Windows 必错，**建议 MT5 类组件显式写 cmd_win**） |
| `process(migrate)` | venv 内执行（PowerShell 调 `.venv\Scripts\python.exe`） |
| `companions` | 每项一个 NSSM 服务 `<name>`（伴随进程无端口） |
| `routes(...)` | 一期不支持 → preflight 即报错退出 |
| `health_url` / `post_deploy_check_path` | curl.exe 探活，3 次重试，失败计败（与 L9 闭环一致） |

config_loader.py：`_KEY_MAP` 增加 `cmd_win` 映射一处 + bash-eval 白名单一处
（按 CHANNEL-CONTRACT §7 核对清单第三条）。

### D6 env 单源化沿用：`deploy.env.server-win-*`

新 env 文件沿用 servers 单源化约定，Windows 专属键：

```ini
DEPLOY_CHANNEL=win
PROJECT_BASE=D:/wwwroot/project        # Windows 路径形态，键名不变
WIN_PYTHON=C:/Python313/python.exe     # 目标机 Python（或受管路径）
NSSM_EXE=D:/Tools/nssm.exe             # 缺省回落 dist assets 自带
# DOMAIN 等键照常（无对外路由时仅作标识）
```

`SERVER_IP`/`DOMAIN` 缺失时该 env 不入 _shared.toml servers 表——与 vm env 同行为，
无影响。

### D7 权限模型：服务安装需管理员

NSSM 安装/启停 Windows 服务要求 elevated。文档约定两条路径：
- 远程：OpenSSH 管理员组成员连接（默认完整 token）+ deploy-win.ps1 启动时
  检测管理员身份，非 elevated 直接报错退出（不给半成功状态）
- 本机：以管理员运行 PowerShell 后执行 `-Local`

### D8 契约同步面（改一处同步 N 处的清单）

| 文件 | 改动 |
|---|---|
| `project-configs/CHANNEL-CONTRACT.md` | §1 通道枚举加 win；§4 翻译表加 win 列；§5 实现现状加行；§7 核对清单更新 |
| `project-configs/KINDS-CONTRACT.md` | python kind 行为表从「双端」扩为「三端」（pack.ps1 / deploy-kinds.sh / deploy-win.ps1） |
| `project-configs/PROJECT-TOML-GUIDE.md` | `cmd_win` 键说明 + win 通道小节 |
| `scripts/channels/registry.sh` | `DEPLOY_CHANNEL` 枚举加 `win`（合法值校验；真实 win 目标不走 bash 链，registry 只做「在 Linux 目标误配 win」的清晰报错引导） |
| `tests/run-all.sh` 第 9 项 | 动词审计扩展：除扫描 bash 通道外，同步扫描 deploy-win.ps1 的 16 个同名 function |
| `docs/guide/manual-deploy-win.md` | 新增（P3 收口时写，先占位链接） |

### D9（★实施期勘误，2026-11-13 调研实证）进程托管双形态

**NSSM 服务形态对 MT5 类组件不适用**——`mt5-bridge-service/svc_entry.py` 头注实证
（2026-11-13 主形态切换）：MetaTrader5 IPC 需要交互式桌面会话，Windows 服务
（Session 0 / LocalSystem）形态下 terminal↔python 通道超时；用户会话前台运行是
MetaQuotes 官方推荐模式。现役 bridge 已弃用 pywin32 服务形态。

⇒ TOML 新增可选意图键 `process.hosting`（缺省 `service`）：

| hosting | 实现 | 适用 |
|---|---|---|
| `service`（缺省） | NSSM Windows 服务（AppDirectory/AppParameters/日志重定向/自动重启） | 不依赖交互桌面的普通 Python 后端 |
| `user-session` | 用户会话后台进程：`Start-Process -WindowStyle Hidden` + PID 文件（`logs/<svc>.pid`）+ stdout/stderr 重定向 `logs/<svc>.out.log`；停止=Stop-Process；自启可选 `shell:startup` 快捷方式 | MT5 依赖组件（bridge、ea-lab-api 的 MT5 爬虫） |

附带收益：mt5-bridge 试点走 `user-session` 形态，**不依赖 NSSM**（本机无 NSSM 的
现状不阻塞 P1）；NSSM 于 P2 前下载入 `dist assets` 备用。

---

## 3. win 通道 16 动词映射表（契约 → PowerShell 实现）

| 动词 | Windows 实现（deploy-win.ps1 内同名函数） |
|---|---|
| `channel_name` | echo `win（NSSM + 无路由）` |
| `channel_supported_kinds` | echo `python` |
| `channel_wants_host_venv` | echo `1` |
| `channel_routing_sync` | no-op + warn（一期无路由层，明确提示） |
| `channel_frontend_prepare/preserve/restore/finalize` | 报「win 通道一期不支持 frontend」并返回失败（比静默 no-op 安全） |
| `channel_python_install` | NSSM 服务安装：服务名=id；AppDirectory=deploy_path；AppParameters=解析 `cmd_win`（`__VENV__` 占位符→`.venv\Scripts\` 绝对路径）；AppStdout/Stderr→`logs\`；启动类型=自动 |
| `channel_python_restart` | `nssm restart <id>` + 轮询 `nssm status` 确认 SERVICE_RUNNING（吸取宝塔 RestartProject 端口竞态教训：stop/start 连发加状态轮询兜底） |
| `channel_java_install/restart` | 报不支持（kind 声明已拦，动词占位保契约完整） |
| `channel_service_running` | `nssm status <svc>` -eq SERVICE_RUNNING |
| `channel_service_restart` | 单服务 `nssm restart` |
| `channel_status` | 遍历全部 NSSM 服务 + health_url 探活，输出与 native channel_status 同构的表 |
| `channel_logs` | `Get-Content logs\<svc>.out.log -Tail N / -Wait`（NSSM 重定向日志），error 模式=Select-String 过滤 |

## 4. python kind 在 Windows 的部署流程（deploy-win.ps1 主链路）

```
1. 环境装载    读 deploy.env.server-win-*（DEPLOY_CHANNEL=win 校验）+ config_loader.py 运行时 manifest
2. preflight   管理员权限 / WIN_PYTHON 存在 / tar.exe / curl.exe / nssm.exe / lock 文件获取
3. 备份        deploy_path → backup/<id>/<TS>/（排除 .venv，保留上限 MAX_BACKUPS=5）
4. 清空        deploy_path 清空但保留 .env/.venv/logs/data（L9 等价名单）
5. 解压        tar -xzf packages/<artifact> -C deploy_path
6. .env 渲染   模板占位符 __PG_PASSWORD__ 等 → PowerShell -replace（值来自 env）
7. 依赖        python -m venv .venv（已存在则跳过）→ .venv\Scripts\pip install -r requirements.txt
               （腾讯源；MetaTrader5 在此正常安装——Linux 上这一步根本装不上）
8. 迁移        process.migrate 存在时 venv 内执行
9. 服务化      channel_python_install（NSSM）→ channel_python_restart（状态轮询）
10. 健康门     curl.exe health_url ×3，失败计败 + 提示 --rollback
11. 汇总       deploy.log 审计行（与 Linux 同格式，含包文件名）
```

回滚：`deploy-win.ps1 <id> -Rollback` 反向复制备份目录 + 重启服务（语义与
core/backup-rollback.sh 对齐；find 排除名单与第 4 步保持一致——KINDS-CONTRACT 铁律 3）。

## 5. 实施分期

| 阶段 | 内容 | 依赖 |
|---|---|---|
| P0 | 本设计文档评审定稿（用户拍板 D1–D8） | ← 当前 |
| P1 | deploy-win.ps1 骨架 + 16 动词 + 本机模式（-Local）；mt5-bridge/project.toml 接入；**在本机试验位从零部署 bridge 试点全绿**（不碰现役 bridge 服务，试验目录+试验端口） | P0 |
| P2 | 远程 OpenSSH 真机验证（目标机到位后：启用 OpenSSH Server → 上传链路二选一定型 → 远程部署试点） | P1 + 目标机 |
| P3 | 契约文档五处同步 + tests/run-all.sh 审计扩展 + manual-deploy-win.md + 通道矩阵图更新 | P1（文档可并行） |

工作量：P1 ≈ 1 个工作日（AI 辅助口径）；P2 半日（目标机到位后）；P3 半日。

## 6. 风险与待验证项

| # | 风险/待验证 | 处置 |
|---|---|---|
| R1 | OpenSSH 上传链路未实测（scp vs ssh 管道） | P2 首项验证；失败不影响 P1 本机模式 |
| R2 | NSSM 需要目标机放 nssm.exe | dist assets 自带 + env 可覆盖路径；无许可证问题（公共域） |
| R3 | 服务安装权限（R7/D7） | 启动时 elevated 检测 fail-fast |
| R4 | MetaTrader5 包运行期依赖目标机已装 MT5 终端 | 属部署前检查项（terminal_path 探测），写入 preflight 提示而非硬失败（bridge 支持后配） |
| R5 | deploy-win.ps1 与 deploy.sh 的 .env 渲染/清空名单漂移 | 两处名单都引用 KINDS-CONTRACT 铁律原文，tests 审计加名单一致性检查 |
| R6 | `cmd_win` 缺省回退 `cmd` 在 POSIX 形态路径上必错 | MT5 类组件约定显式写 cmd_win；GUIDE 中标注 |

## 7. 非目标（一期明确不做）

- frontend/java/go/nodejs kind 的 Windows 部署
- Windows 路由层（Nginx for Windows / IIS）
- WinRM 协议、PowerShell Remoting
- 宝塔 Windows 面板对接
- docker Windows 容器
