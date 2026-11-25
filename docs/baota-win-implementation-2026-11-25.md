# winvm 宝塔化改造落地说明（2026-11-25）

> 设计稿：[baota-win-redesign-2026-11-25.md](baota-win-redesign-2026-11-25.md)。
> 本文档记录实际落地过程、终态架构、与设计稿的差异，以及全量实战坑。
> 目标机：WinServer 虚拟机 winvm（192.168.31.200，Server 2025 内核 26100，SSH alias `winvm`）。

## 1. 终态架构（6 服务 / 6 端口，全绿）

| 组件 | 归属 | 形态 | 端口 |
|---|---|---|---|
| 宝塔面板 | btPanel / btTask 服务 | Windows 面板（Python 架构，C:\BtSoft） | 8888 |
| nginx | 宝塔 | 站点 fin.local（siteId=2）+ proxy/rewrite 槽位 | 80 |
| PostgreSQL | **原生 pg_ctl 服务** postgresql-quant | `C:\opt\pgsql\bin\pg_ctl.exe runservice -N postgresql-quant -D C:\opt\pgsql\data-quant` | 5432 |
| Redis | 宝塔 | 无密码 RESP2 | 6379 |
| financial-api | 宝塔 Python 项目 = 原生服务 `python_site_financial-api` | wrapper service.exe + service.json | 5001 |
| mt5-bridge | user-session（Administrator 交互会话） | schtasks `\mt5-bridge` + 宝塔计划任务守护 | 9199 |

- HTTP 验证：`Host:192.168.31.200` 下 `/` 200、`/admin/` 200、`/api/health` 200。
- NSSM **零残留**（服务/二进制/C:\opt 均清场）；不保留 win 通道回退。

## 2. 阶段实录（M0-M6）

| 阶段 | 内容 | 关键动作 |
|---|---|---|
| M0 | 安装面板 v8.5.2（Go 后端） | BtSoft.exe 无静默安装——计划任务拉到桌面由用户点击完成；API 密钥 UI 开启（limit_addr 含 127.0.0.1） |
| M1 | Nginx 站点收编 | 站点 fin.local root=financial-web/dist；/admin/ alias 与 /api/ 反代写入 `C:\BtSoft\nginx\conf\{proxy,rewrite}\fin.local\*.conf` 槽位 |
| M2 | PG/Redis 去 NSSM | PG → 原生服务 postgresql-quant；Redis → 宝塔软件商店 |
| M3 | financial-api 收编 | 面板 Python 项目（名 financial-api，项目路径 package\package，venv 由部署器管理） |
| M4 | MT5 桥守护 | 宝塔计划任务「MT5桥守护」（id=3，每 5 分钟 curl 9199/health，mt5Initialized!=true 则 `schtasks /run /tn mt5-bridge`）；闭环测试杀桥 45s 内复活 |
| M5 | 清场 | NSSM 服务全删、schtasks mt5-startterm-*/pytest1 删、C:\opt 只剩 pgsql |
| M6 | deploy 侧对接 | 新通道 baota-win（见 §4）；winvm 实测 -List/-Status/-Logs/preflight/RestartOnly/frontend 部署全通过 |

## 3. 与设计稿的差异（用户拍板覆盖）

| 设计稿假设 | 实际落地 |
|---|---|
| PG 建议"继续 NSSM"（R4） | PG 用**原生 pg_ctl 服务** postgresql-quant（NSSM 全退役） |
| 保留 win 通道作为回退（待拍板项 4） | **不保留**，win/NSSM 通道退役 |
| M2/M3 有独立回退点（nssm start ...） | 无回退点，一步到位 |

## 4. baota-win 通道（M6 交付物）

- **env**：[deploy.env.server-baota-win](../deploy.env.server-baota-win)（`DEPLOY_CHANNEL=baota-win`，宝塔面板地址/密钥、站点 id、python 项目服务名前缀、.env 渲染键）
- **执行器**：[scripts/deploy-win-baota.ps1](../scripts/deploy-win-baota.ps1)（deploy-win.ps1 的宝塔化分叉，同 16 动词契约；目标机自包含，winvm 上为 `C:\deploy\scripts\`）
- **契约登记**：[CHANNEL-CONTRACT.md](../project-configs/CHANNEL-CONTRACT.md) §1/§4/§5 已加 baota-win；win 通道标记已退役
- **托管映射**：
  - python hosting=service → 宝塔 Python 项目 = 原生 Windows 服务 `python_site_<id>`，重启/状态直接 `Restart-Service`（与面板操作语义等价）
  - python hosting=user-session → 同 win 通道会话进程 + 宝塔计划任务守护兜底
  - nginx 站点/反代 → 宝塔所有权，脚本只校验（面板 API `site/get_site_info` + proxy/rewrite 槽位文件在位），不改写
- **面板 API 前置校验**（部署/回滚/重启前自动跑）：`config/get_config`（API 可达）→ `site/get_site_info siteid=<BT_SITE_ID>`（站点 root 在 PROJECT_BASE 下）→ `C:\BtSoft\python_site\<id>\service.json` + 服务存在（service 组件）

**验证记录（2026-11-25 winvm 实测）**：
- `-List`：9 组件枚举，kind 断言通过
- `-Status`：financial-api RUNNING 200；mt5-bridge RUNNING 200（PID 文件过期场景经端口兜底修正）
- `-RestartOnly financial-api`：前置校验 → Restart-Service → 健康门 200（第二次探测通过，含端口竞态防护）
- `financial-admin` 前端实部署：备份 → 清空 → 平铺解压 → 231 文件，/admin/ 复验 200
- `-Logs financial-api`：指向宝塔项目日志 `C:\BtSoft\python_site\financial-api\logs\{service.log,error.log}`

## 5. 面板 API 逆向结论（v8.5.2 Go 后端）

- Base `http://127.0.0.1:8888/<module>/<action>`，**根路径，不带 admin path**
- 签名 `request_token = md5(request_time + md5(token))`（双重 md5）
- form 与 JSON body 均可；**crontab 系列 time 参数必须 JSON body**（Go 结构体 v1.CrontabTime）
- 站点参数名 `siteid`（非 id）；`site/get_site_info` fullPath 为正斜杠
- Linux 面板老 API（/site?action=AddSite）在 Windows Go 后端**不存在**
- **python 项目无列表/重启端点**（SPA 只有 create/delete/set_site）；`project/get_project_logs|load_status` 要数字 id 且无从获取；datalist 无 python_project 表 → **项目操作一律走原生服务，面板 API 只用于站点/前置校验**
- crontab toShell 以 SYSTEM/Session 0 运行 → MT5 桥不能直接放计划任务，只能做守护代理
- API 客户端：[tmp/bt-win-api.py](../tmp/bt-win-api.py)（本地 + winvm `C:\deploy\setup\`）

## 6. 实战坑清单（全量）

1. **SSH 嵌套引号极易碎**：复杂命令一律写 ps1/py 脚本 scp 到 `winvm:C:/deploy/setup/` 再执行。
2. **PS5.1 脚本勿放中文**（无 BOM 会乱码）；本地 console GBK 乱码可忍（仅显示层）。
3. BtSoft.exe 无静默安装：计划任务（LogonType Interactive）拉到桌面，用户点击完成。
4. 面板登录流程复杂（RSA+last_login_token+session），**勿尝试程序化登录**，走 UI 开 API。
5. crontab/add time 参数是 Go 结构体：必须 `Content-Type: application/json`，form 表单报 reflect.Convert 错。
6. crontab 列表端点是 `datalist/get_data_list (table=crontab)`；`crontab/start` 用 `id=`。
7. MT5 IPC 需交互式桌面会话（Session 0 不通）→ 桥本体由 schtasks `\mt5-bridge`（Administrator+Interactive+LogonTrigger）在用户会话拉起，宝塔计划任务只做健康守护。
8. NSSM 把正常输出写 stderr + PS5.1 `$ErrorActionPreference=Stop` 会把 2>&1 抛成 NativeCommandError（历史坑，win 通道已实证；baota-win 无 NSSM 免疫此坑）。
9. 宝塔 redis 无密码、RESP2（桥日志 HELLO fallback warning，无害）。
10. winvm 的 D: 是 CD-ROM，路径一律 C:。
11. python_site 服务日志是唯一权威运行日志（PKG logs 下 NSSM 时代的 *.out.log 是遗留空文件，勿混淆）。
12. 宝塔面板升级后必跑回归清单（设计稿 §6），重点复查「MT5桥守护」计划任务安全选项仍是"登录用户+最高权限+未勾不管登录"。
13. ★建站覆盖坑（M1 踩实）：宝塔建站时往站点 root 写默认欢迎页 index.html（640B），**覆盖已部署 SPA 的 index.html**——首页变 Welcome to nginx 但状态码仍 200，/admin/（alias）与 /api/（反代）都正常，极具迷惑性。验证必须看响应体 title（应=深量科技），不能只看状态码；修复 = 重发 financial-web。

## 7. 后续事项

- 通道标识切 baota-win 后，`tests/run-all.sh` 动词审计暂不覆盖 PowerShell 分叉（与 win 通道同状态），需要时在 tests 里加 deploy-win-baota.ps1 扫描。
- registry.sh 未登记 baota-win（Linux 侧文件不动）；误配由执行器自身的 `DEPLOY_CHANNEL=baota-win` 校验兜底。
