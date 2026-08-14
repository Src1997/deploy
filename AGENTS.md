# AGENTS.md — Deploy Repository

> **Category**: Guide (Agent Entry Point)
>
> 本文件是 AI Agent 进入 `deploy/` 仓库的入口，提供架构导航和不可妥协项。

## 仓库定位

多项目宝塔部署工具箱：从零搭建服务器 → 配置驱动打包 → 增量部署/回滚 → 日常运维。
本地 Windows 构建（PowerShell），服务器 Ubuntu/宝塔运行（Bash）。

## 目录结构

```
deploy/
  scripts/
    build.ps1              # 入口：构建 + 打包 + 同步 dist/
    pack.ps1               # 单项目打包器（被 build.ps1 调用）
    deploy.sh              # 服务器部署主入口（471 行，lib/ 加载功能模块）
    deploy-financial-api.sh # financial-api 专用部署钩子
    lib/                   # 共享库（Bash + PowerShell）
      common.sh            # 颜色、日志、CRLF 修复、新鲜度检查（101 行）
      preflight.sh         # 部署前检查（102 行）
      service-ops.sh       # 服务重启、健康检查、状态总览、日志查看（143 行）
      backup-rollback.sh   # 备份与回滚（247 行）
      nginx.sh             # Nginx 配置生成与部署（126 行）
      deploy-kinds.sh      # 各类型部署函数（frontend/python/java/go/nodejs）（542 行）
      deploy-dispatch.sh   # 部署调度逻辑：批量部署、排序、摘要（98 行）
      interactive.sh       # 交互式菜单与部署/回滚选择（197 行）
      load-deploy-env.sh   # 环境变量加载（88 行）
      load-projects.sh     # 项目清单加载（从 TOML via config_loader.py）（45 行）
      config_loader.py     # TOML 配置直接读取器（替代 sync-manifest.py + projects.json）
      _ps-common.ps1       # PowerShell 共享常量与日志函数
    ops/                   # 一次性运维脚本（服务器初始化、WSL 工具）
      01-cleanup-server.sh    # Phase 1: Docker + 系统冲突清理
      lib-clear-conflicts.sh  # 系统冲突清理子模块（被 01 调用，也可单独跑）
      02-install-baota.sh     # Phase 2: 安装宝塔面板（输出手动安装组件指引）
      03-check-components.sh  # Phase 3: 检查宝塔组件是否全部安装完成
      04-setup-server.sh      # Phase 4: 创建数据库和目录（开头调用 03-check）
      wsl-*.ps1 / wsl-autostart.sh
    tools/                 # 工具脚本
      detect-status.sh     # 部署进度检测
      generate-nginx.py    # Nginx 配置生成器
  configs/                 # 配置模板（.env.example、systemd service）
  project-configs/         # 项目配置 SSOT（TOML 格式）
    _shared.toml           # 跨项目共享默认值
    <name>/project.toml    # 单项目配置
  dist/                    # 构建产物（gitignore，由 build.ps1 生成）
  docs/                    # 文档
  tests/                   # 测试脚本
  deploy.env*              # 环境配置（gitignore）
```

## 核心数据流

```
project-configs/*.toml → config_loader.py (运行时直接读取)
                           ↓
build.ps1 → pack.ps1 → dist/packages/*.tar.gz
    ↓
build.ps1 → Copy-DeployAssets → dist/ (自包含部署包)
    ↓
scp dist/ → server:/www/wwwroot/project/uploads/
    ↓
bash deploy.sh → lib/*.sh → 部署/回滚/状态/日志
```

## Non-Negotiables

1. **密码只放 `deploy.env*`**，禁止写进脚本或文档或 Git。
2. **项目配置走 TOML**（`project-configs/`），不硬编码到脚本。
3. **`dist/` 是自包含的**：服务器上 `bash deploy.sh` 无需源码目录。
4. **`lib/` 模块只被 source，不直接执行**。
5. **`deploy.sh` 主文件 ≤ 500 行**：功能函数拆到 `lib/*.sh`，主文件只保留参数解析、交互菜单、主入口。
6. **Shell 选择**：打包/构建用 Windows PowerShell；部署/测试/运维用 WSL Ubuntu Bash。
7. **最小 diff**：每次改动聚焦一个关注点，不混合无关变更。
8. **不主动 commit**：除非用户明确要求。

## 关键文件索引

| 你想… | 看哪里 |
|---|---|
| 加新项目 | `project-configs/<name>/project.toml` + `configs/<name>.env.example` |
| 改部署逻辑 | `scripts/lib/deploy-kinds.sh`（按 kind 分发） |
| 改备份/回滚 | `scripts/lib/backup-rollback.sh` |
| 改 Nginx 生成 | `scripts/tools/generate-nginx.py` |
| 改 preflight 检查 | `scripts/lib/preflight.sh` |
| 改打包逻辑 | `scripts/pack.ps1` |
| 查部署文档 | `docs/guide/` 下按场景选择 |
| 查排障历史 | `docs/deploy-troubleshooting-history.md` |

## 架构决策

### deploy.sh 模块化拆分（2026-08-12，更新 2026-08-13）

`deploy.sh` 从 2107 行拆分为 471 行主文件 + 8 个 lib 模块：
- 主文件保留：帮助、参数解析、环境加载、主入口逻辑（471 行）
- `lib/common.sh`：颜色、日志、CRLF、新鲜度（101 行）
- `lib/preflight.sh`：pre-flight 检查（102 行）
- `lib/service-ops.sh`：服务操作（143 行）
- `lib/backup-rollback.sh`：备份回滚（247 行）
- `lib/nginx.sh`：Nginx（126 行）
- `lib/deploy-kinds.sh`：5 种部署函数（542 行）
- `lib/deploy-dispatch.sh`：部署调度逻辑：批量部署、排序、摘要（98 行）
- `lib/interactive.sh`：交互式菜单与部署/回滚选择（197 行）
- `lib/load-deploy-env.sh`：环境变量加载（88 行）
- `lib/load-projects.sh`：项目清单加载（45 行）

### 目录分层（2026-08-12）

`scripts/` 从扁平结构重组为分层结构：
- `scripts/`：核心构建和部署脚本（build.ps1、pack.ps1、deploy.sh 等）
- `scripts/lib/`：共享库（Bash + PowerShell）
- `scripts/ops/`：一次性运维脚本（服务器初始化、WSL 工具）
- `scripts/tools/`：工具脚本（detect-status、generate-nginx）
