# baota-win 通道 · AI 使用文档

> 面向 AI 助手在 winvm（192.168.31.200）上执行部署/诊断/运维的完整操作手册。
> 背景与落地过程见 [baota-win-implementation-2026-11-25.md](baota-win-implementation-2026-11-25.md)。

## 0. 红线（先读）

1. **Linux 侧 deploy 通道一行不动**（deploy.sh / channels/baota.sh / baota_api.py 仅参考）。
2. **NSSM 永不回归**：任何"装个服务"的需求走宝塔 Python 项目或原生 Windows 服务，不装 NSSM。
3. **不尝试程序化登录宝塔面板**（RSA+session 流程复杂），一切面板操作走 API 密钥。
4. **MT5 桥不进宝塔计划任务本体**（SYSTEM/Session 0 下 MT5 IPC 不通）；计划任务只做守护代理。
5. 复杂远程命令**不要内联 SSH 引号**，写脚本 scp 到 `winvm:C:/deploy/setup/` 执行。
6. PS5.1 脚本文件内容避免中文（无 BOM 乱码）；响应用中文没关系。

## 1. 机器与凭据

| 项 | 值 |
|---|---|
| SSH | `ssh winvm`（192.168.31.200，Administrator） |
| 面板 URL | http://192.168.31.200:8888/J0w3RuMt |
| 面板账号 | 6cWqvAfY / Bt@Winvm2026! |
| 面板 API token | `dOWpXIyCbWASTwhnWGPKJjkJTCbqIeQU`（limit_addr 含 127.0.0.1） |
| 部署根（目标机） | C:\deploy（scripts / dist\packages / project-configs / configs / deploy.env.server-baota-win） |
| 项目根（目标机） | C:\wwwroot\project |

## 2. 部署（本地仓库侧）

```powershell
# 1. 本机打包（D:\Workspace\deploy）
powershell -File scripts\pack.ps1 financial-api        # 或 financial-web / financial-admin / mt5-bridge

# 2. dist 同步到目标机
scp -r dist\packages\ winvm:C:/deploy/dist/packages/   # 或 rsync/scp 按需
scp scripts\deploy-win-baota.ps1 winvm:C:/deploy/scripts/
scp deploy.env.server-baota-win winvm:C:/deploy/

# 3. 目标机部署（baota-win 通道）
ssh winvm "powershell -ExecutionPolicy Bypass -File C:/deploy/scripts/deploy-win-baota.ps1 <组件id> -Target server-baota-win -Yes"
```

- 组件 id：financial-web / financial-admin / financial-api / mt5-bridge（其余 deepquant、demo、official-site 未在 winvm 落地）。
- 多组件：`deploy-win-baota.ps1 financial-web financial-admin financial-api -Target server-baota-win -Yes`。
- 前置校验自动执行（面板 API / 站点 / Python 项目登记）；应急跳过加 `-SkipPreflight`。
- 部署不重启：`-NoRestart`；只重启：`-RestartOnly`；回滚：`-Rollback` / `-RollbackTo <ts>`。

## 3. 日常运维动词

```powershell
ssh winvm "powershell -ExecutionPolicy Bypass -File C:/deploy/scripts/deploy-win-baota.ps1 -Target server-baota-win -Status"
ssh winvm "powershell -ExecutionPolicy Bypass -File C:/deploy/scripts/deploy-win-baota.ps1 -Target server-baota-win -Logs financial-api -Mode 50"   # follow/error/N
ssh winvm "powershell -ExecutionPolicy Bypass -File C:/deploy/scripts/deploy-win-baota.ps1 financial-api -Target server-baota-win -RestartOnly -Yes"
```

服务级操作（绕过部署器，直接原生服务）：

```powershell
ssh winvm "powershell -Command Restart-Service python_site_financial-api"   # 宝塔 Python 项目 = 原生服务
ssh winvm "powershell -Command Get-Service btPanel,btTask,nginx,postgresql-quant,redis,python_site_financial-api | ft Name,Status"
curl http://192.168.31.200/api/health     # 全栈健康（database/redis 状态在内）
curl http://127.0.0.1:9199/health         # 桥健康（winvm 上；看 mt5Initialized 字段）
```

## 4. 宝塔面板 API（签名调用）

客户端：本地 `D:\Workspace\deploy\tmp\bt-win-api.py`，winvm 上 `C:\deploy\setup\bt-win-api.py`。

```bash
ssh winvm "C:/Users/Administrator/AppData/Local/Programs/Python/Python312/python.exe C:/deploy/setup/bt-win-api.py <module/action> k=v ..."
# JSON body（crontab 必需）: bt-win-api.py --json @file.json
```

- 签名：`request_token = md5(t + md5(token))`；Base=面板端口根路径（**不带** admin path）。
- 常用：`config/get_config`（探活）、`site/get_site_info siteid=2`、`site/get_site_proxy_list siteid=2`、`datalist/get_data_list table=crontab`（JSON body）、`crontab/start id=3`、`ajax/get_task_list`。
- **python 项目没有列表/重启端点**——直接操作原生服务 `python_site_<id>`。

## 5. 诊断决策树

| 症状 | 排查顺序 |
|---|---|
| /api/health 不通 | ① `Get-Service python_site_financial-api` ② 宝塔项目日志 `C:\BtSoft\python_site\financial-api\logs\{service.log,error.log}` ③ `-Logs financial-api` ④ 5001 端口监听 |
| 页面 502/白屏 | ① 宝塔 nginx 服务 ② `C:\BtSoft\nginx\conf\proxy\fin.local\api.conf` 反代槽位在位？ ③ dist 是否被部署清空（backup 目录找最近备份） |
| PG 连不上 | `Get-Service postgresql-quant`；数据目录 `C:\opt\pgsql\data-quant`（pg_ctl 原生服务） |
| MT5 桥 /health 不通 | ① 等守护任务 5 分钟自动拉起（schtasks `\mt5-bridge`）② 手动 `schtasks /run /tn mt5-bridge` ③ 必须 **Administrator 登录会话**存在；宝塔升级后复查计划任务安全选项（登录用户+最高权限） |
| 部署锁卡死 | 删 `C:\wwwroot\project\deploy.win.lock` |
| API 调用 404 | 路径不带 admin path；端点不存在（Linux 老 API 全部无效） |
| API"密钥校验失败" | 签名要双重 md5；token 过期去面板 UI 重取 |

## 6. 回归验证清单（每次部署/宝塔升级后）

1. `curl http://192.168.31.200/ /admin/ /api/health` 全 200。
2. `deploy-win-baota.ps1 -Status`：financial-api 与 mt5-bridge 均 RUNNING 200。
3. MT5 实采：winvm 上 `curl "127.0.0.1:9199/rates?symbol=XAUUSD&timeframe=H1&count=3"` 返回 K 线（IPC 会话有效）。
4. 守护闭环：杀桥进程 → ≤5 分钟内复活（守护任务生效）。
5. 服务清单：btPanel / btTask / nginx / postgresql-quant / redis / python_site_financial-api 全 Running。
