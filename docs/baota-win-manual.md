# winvm（192.168.31.200）宝塔化部署 · 人工使用文档

> 给人类运维的日常操作手册。技术细节与 AI 协作流程见
> [baota-win-ai-guide.md](baota-win-ai-guide.md) 与 [baota-win-implementation-2026-11-25.md](baota-win-implementation-2026-11-25.md)。

## 1. 这台机器是什么

winvm 是金融项目的 Windows 全栈部署机：宝塔面板统一管理网站/nginx/Redis/Python 项目，
PostgreSQL 走原生 Windows 服务，MT5 行情桥跑在管理员桌面会话。**没有 NSSM**，
一切"后台服务"不是宝塔项目就是原生服务。

## 2. 常用入口

| 什么 | 在哪 |
|---|---|
| 宝塔面板 | http://192.168.31.200:8888/J0w3RuMt （账号 6cWqvAfY，见密码管理器） |
| 网站 | 面板 → 网站 → fin.local（root = C:\wwwroot\project\financial\financial-web\dist） |
| Python 项目 | 面板 → Python项目 → financial-api（对应 Windows 服务 `python_site_financial-api`） |
| MT5 桥守护 | 面板 → 计划任务 → 「MT5桥守护」（每 5 分钟） |
| Redis | 面板 → 软件商店 → Redis（无密码，仅内网） |
| PostgreSQL | 服务 `postgresql-quant`（**不走宝塔**，数据在 C:\opt\pgsql\data-quant） |
| 部署脚本 | 目标机 C:\deploy\scripts\deploy-win-baota.ps1；仓库 D:\Workspace\deploy |

## 3. 发一次版（标准流程）

在**开发机** D:\Workspace\deploy 执行：

```powershell
# ① 打包要发的组件
powershell -File scripts\pack.ps1 financial-api
#   前端: financial-web / financial-admin；桥: mt5-bridge

# ② 把包和脚本同步到目标机
scp dist\packages\<新包> winvm:C:/deploy/dist/packages/
scp scripts\deploy-win-baota.ps1 winvm:C:/deploy/scripts/

# ③ 到目标机部署
ssh winvm "powershell -ExecutionPolicy Bypass -File C:/deploy/scripts/deploy-win-baota.ps1 financial-api -Target server-baota-win -Yes"
```

脚本会自动做：宝塔前置校验 → 备份 → 解压新代码 → 装依赖 → 数据迁移 → 重启服务 → 健康检查。
失败会保留备份并提示回滚命令。

## 4. 日常操作速查

```powershell
# 看全部服务状态
ssh winvm "powershell -ExecutionPolicy Bypass -File C:/deploy/scripts/deploy-win-baota.ps1 -Target server-baota-win -Status"

# 看后端日志（最近 50 行；follow=实时，error=只看错误）
ssh winvm "powershell -ExecutionPolicy Bypass -File C:/deploy/scripts/deploy-win-baota.ps1 -Target server-baota-win -Logs financial-api -Mode 50"

# 只重启后端（改完配置后用）
ssh winvm "powershell -ExecutionPolicy Bypass -File C:/deploy/scripts/deploy-win-baota.ps1 financial-api -Target server-baota-win -RestartOnly -Yes"

# 回滚到上一版（交互选备份点）
ssh winvm "powershell -ExecutionPolicy Bypass -File C:/deploy/scripts/deploy-win-baota.ps1 financial-api -Target server-baota-win -Rollback"
```

浏览器验证：打开 http://192.168.31.200/ （行情页）、http://192.168.31.200/admin/ （管理后台）、
http://192.168.31.200/api/health （应返回含 `"status":"ok"`）。

## 5. 出问题怎么办

| 现象 | 人工处理 |
|---|---|
| 网站打不开 | 远程桌面登录 winvm → 宝塔面板 → 网站，看 nginx 是否运行、站点是否停止 |
| /api/health 报错 | 面板 → Python项目 → financial-api → 日志，或直接重启项目；服务名 `python_site_financial-api` 也可在 services.msc 重启 |
| 数据库错误 | services.msc → `postgresql-quant` 是否运行（PG 不归宝塔管） |
| 行情不动（MT5 桥） | ① 等 5 分钟（守护任务会自动拉起）② 不行就远程桌面确认 **Administrator 已登录桌面**（桥跑在桌面会话里，注销会挂）③ 手动跑任务计划程序里的 `mt5-bridge` 任务 |
| 部署失败 | 输出里有备份路径；用 `-Rollback` 回滚后排查，别硬再发 |
| 忘记面板密码 | winvm 上管理员 PowerShell 执行 `cd C:\BtSoft\panel && python tools.py panel` 重置 |

### 5.1 VM 重启/断电恢复后必查（2026-11-26 实证）

| 检查项 | 现象与处置 |
|---|---|
| 宝塔面板服务 | btPanel/btTask/BTAGService 可能 Stopped（8888 不通、deploy preflight 失败"无法连接远程服务器"）→ 管理员 PowerShell：`Start-Service btPanel,btTask,BTAGService`；**建议核查其自启配置** |
| api 服务 | `python_site_financial-api` 可能 Stopped → services.msc 或面板启动 |
| MT5 桥 | 计划任务 `mt5-bridge` 触发器=**登录时**、仅交互式——必须 **Administrator 登录桌面**才自动拉起；登录后看 `/health`（mt5Initialized）与日志（启动窗口期 10:29 类 `-10004` 为 MT5 终端重连瞬态，恢复后应归零） |
| RCC 配置 | 若发现 api→桥 401/地址缺失，查 `fin_data_source_configs` 的 `ea.api_base_url` / `ea.api_token`（2026-11-26 曾发现丢失并补插；token 与桥 config.ini `[server] api_token` 同值） |
| 前端验证 | 浏览器访问 `http://192.168.31.200/`（注意：**127.0.0.1 Host 会落 nginx 默认 server**，非 D-F1 复发） |

> 另：pack.ps1 依赖 config_loader.py（scripts/core/），脚本有更新时同步 `scripts\` 与 `project-configs\` 到目标机，勿只传 deploy-win-baota.ps1。

## 6. 每次宝塔升级后必查

1. 网站 fin.local 正常：首页/后台/api 三件套 200，且**首页页面标题是「深量科技」**
   （宝塔建站/重装站点时会往站点根写默认欢迎页，只看 200 看不出来）。
2. 计划任务「MT5桥守护」的安全选项仍是：**登录用户 + 最高权限 + 不勾"不管用户是否登录"**。
   （升级可能重置此选项 → MT5 桥会挂）
3. Administrator 保持登录状态（桥依赖桌面会话；重启后需登录一次）。
4. `deploy-win-baota.ps1 -Status` 两个核心服务 RUNNING。

> 若首页变成 "Welcome to nginx!"：重发一次前端即可恢复 ——
> `deploy-win-baota.ps1 financial-web -Target server-baota-win -Yes`

## 7. 备份与回滚

- 每次部署自动备份到 `C:\wwwroot\project\backup\<组件id>\<时间戳>\`，默认留 5 份。
- `.env`、`.venv`、`logs`、`data` 不在备份/清空范围（部署永不动它们）。
- 数据库备份：宝塔面板 → 数据库 → 定期备份（如未配置建议开启）。

## 8. Worker 守护任务（financial-workers-guard，2026-11-27）

schtasks `\financial-workers-guard` 每 5 分钟跑 `C:\deploy\scripts\win-worker-guard.ps1`：

- **arq worker**：进程存活检查，缺失即按需拉起（VM 重启后不再手工补）；
- **streaming worker**：按 package `.env` 的 `APP_ROLE` / `CRAWLER_ENABLED` 决定启停
  （api 形态按设计不运行，health 里显示 disabled 不算 degraded）；
- **部署窗口豁免**：90s 内有包文件写入（`.venv`/`logs`/`*.pyc` 除外）→ 本轮跳过，
  避免落在部署中间对半写包拉起 worker；部署收尾触发的守护经
  `C:\deploy\scripts\worker-guard.nowait` 标记豁免该检查（守护消费后即删）。

**运维三条铁律**：

1. **手工恢复 worker 一律走 `schtasks /run /tn financial-workers-guard`**——
   ssh 会话里直接跑守护/拉起的进程是 ssh 子进程，**ssh 断开即死**（实测两次踩坑）。
2. **venv 双进程是正常结构**：`.venv\Scripts\python.exe`（启动器）+ 系统
   `Python312\python.exe`（真实子进程，占端口的通常是他）——不要按
   ExecutablePath 杀"非 venv 路径"进程（2026-11-27 误杀教训）。
3. 排查顺序：`Get-CimInstance Win32_Process -Filter "Name='python.exe'"`
   看命令行 → `logs\arq-worker.err.log` → `/api/health/detailed` 的 arq 字段。

## 9. 已知探针陷阱

- winvm 上 `Invoke-WebRequest http://127.0.0.1/` 落 **nginx 默认 server**（返回 640
  字节默认页，不是站点）——web 验证必须用 `http://192.168.31.200/` 或
  `Host: fin.local`（D-F1 口径，2026-11-27 再次踩到）。
