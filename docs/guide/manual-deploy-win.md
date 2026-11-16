# win 通道手动部署（Windows 目标机）

> 通道：`DEPLOY_CHANNEL=win`。执行器 = `scripts/deploy-win.ps1`（PowerShell 平行入口）。
> 设计与决策记录：[docs/win-channel-design-2026-11-13.md](../win-channel-design-2026-11-13.md)。
> **适用**：Windows 目标机上的 Python 组件（MT5 生态：mt5-bridge、ea-lab-api 等
> ——MetaTrader5 包 Windows-only）。Linux 三通道见 manual-deploy.md 分流。

## 一、形态总览

| 项 | 值 |
|---|---|
| kind 支持 | python（一期；frontend/java 报清晰错误） |
| 进程托管 | `process.hosting`：`service`=NSSM（需管理员）/ `user-session`=用户会话后台进程（MT5 IPC 类必用） |
| 路由层 | 无（一期；MT5 组件均为纯后端，对外路由在 Linux 生产机收口） |
| 包格式 | tar.gz（与 Linux 侧同源，pack.ps1 产出；Win10+ bsdtar 解压） |
| 布局 | `PROJECT_BASE\<deployPath>\package\`（app-package），venv 在 PKG_DIR 内 `.venv\` |

## 二、本机模式（P1 试点形态，目标 = 构建机自身）

```powershell
# 1. 打包（本地）
.\scripts\pack.ps1 mt5-bridge

# 2. 部署（-Target 对应 deploy.env.server-win）
.\scripts\deploy-win.ps1 mt5-bridge -Target server-win -Yes

# 3. 状态 / 日志 / 回滚
.\scripts\deploy-win.ps1 -Status
.\scripts\deploy-win.ps1 mt5-bridge -Logs mt5-bridge -Mode 50
.\scripts\deploy-win.ps1 mt5-bridge -Rollback          # 交互选备份
.\scripts\deploy-win.ps1 mt5-bridge -RollbackTo latest -Yes
```

## 三、远程模式（P2，目标 = 独立 Windows 服务器）

前置（目标机一次性手动操作，需管理员 PowerShell）：

```powershell
# 启用 OpenSSH Server（Win10 1809+ / Server 2019+ 内置可选功能）
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic
Start-Service sshd
# 可选：默认 shell 设为 PowerShell（ssh 进去直接是 PS）
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
  -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force
```

上传 + 执行（本地构建机）：

```powershell
# dist 同步到目标机（scp 显式密钥/端口绕开 ~/.ssh/config 读取坑；或 ssh 管道，
# 两者待真机定型——见设计文档 R1）
scp -i <密钥> -P <端口> -r dist\ user@win-host:"D:/wwwroot/project/uploads/"
# 远程执行
ssh -i <密钥> -p <端口> user@win-host "powershell -NoProfile -File D:\wwwroot\project\uploads\dist\scripts\deploy-win.ps1 mt5-bridge -Target server-win -Yes"
```

## 四、env 文件（deploy.env.server-win）

| 键 | 说明 |
|---|---|
| `DEPLOY_CHANNEL=win` | 强制校验，非 win 直接退出 |
| `PROJECT_BASE` | Windows 路径（如 `D:/wwwroot/project`） |
| `WIN_PYTHON` | 目标机 Python 3.11+（tomllib 必需）；缺省 Get-Python 探测 |
| `NSSM_EXE` | hosting=service 时需要；回落 `assets\win\nssm.exe`（[nssm.cc](https://nssm.cc) 下载） |
| `MAX_BACKUPS` | 备份上限（缺省 5） |

## 五、已知限制（一期）

1. **MT5 类组件必须 `hosting = "user-session"`**——NSSM/服务形态（Session 0）下
   MetaTrader5 IPC 不通（svc_entry.py 2026-11-13 实证）；user-session 自启可把
   启动命令快捷方式放进 `shell:startup`。
2. **config.ini 类非-.env 运行时配置不在清空保留名单**（仅 `.env/.venv/logs/data`）——
   每次部署会被包内版本覆盖。mt5-bridge 已在 TOML `extra_exclude_files` 排除
   `config.ini`，部署后按环境手工放置；敏感值走 `MT5_BRIDGE_DB_PASSWORD` 环境变量。
3. **MCP 自动检测 / migrate 一期延后**（对照 Linux deploy-python.sh）。
4. 管理员权限仅在部署 `hosting=service` 组件时强制；user-session 普通权限即可。
