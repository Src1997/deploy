# AGENTS.md — Deploy Repository

> **Category**: Guide (Agent Entry Point)
>
> 本文件是 AI Agent 进入 `deploy/` 仓库的入口，提供架构导航和不可妥协项。

## 仓库定位

多项目部署工具箱：从零搭建服务器 → 配置驱动打包 → 增量部署/回滚 → 日常运维。
本地 Windows 构建（PowerShell），服务器 Ubuntu 运行（Bash）。

**三通道架构（2026-10-22 重构，kind × channel 矩阵）**：部署 = kind（frontend/
python/java，决定"做什么"）× channel（决定"怎么跑"）：
- `baota` 宝塔部署（**主力**，VM 全链路验证）：前端=宝塔站点、Python/Java=宝塔项目，面板可见可管；
- `native` 原生部署（★冻结维护，A/B 应急）：systemd + 宿主 nginx（generate-nginx）；
- `docker` 容器部署（MVP）：python=镜像构建+compose，TOML `docker_port`/`docker_cmd`。
通道选择 `DEPLOY_CHANNEL`（deploy.env 或 `--channel=`；兼容旧 BAOTA_MODE），
契约与动词清单见 `project-configs/CHANNEL-CONTRACT.md`。同一台服务器单通道；
docker 与宝塔不共存。测试分两层：L1 本地快速回归（tests/run-all.sh，含通道动词
完备性审计）+ L2 黄金链路（tests/golden-path-vm.sh，VM 上清场→从零部署→全链路断言）。

## 目录结构

```
deploy/
  scripts/
    build.ps1              # 入口：构建 + 打包 + 同步 dist/
    pack.ps1               # 单项目打包器（被 build.ps1 调用）
    preclean-dist.ps1      # 构建前预清理 dist/（沙箱 Remove-Item 规避）
    _ps-common.ps1         # PowerShell 共享常量与日志函数
    deploy.sh              # 服务器部署主入口（core/ kind/ channel/ 分层加载）
    deploy-python.sh       # Python 后端部署钩子（financial deploy_hook 专用；退役合并待办）
    core/                  # 部署主链路装载层（Bash + 配置装载）
      common.sh            # 颜色、日志、CRLF 修复、新鲜度检查
      load-deploy-env.sh   # 环境变量加载
      load-projects.sh     # 项目清单加载（从 TOML via config_loader.py）
      config_loader.py     # TOML 配置直接读取器（SSOT → manifest → bash-eval/nginx-json）
      preflight.sh         # 部署前检查
      service-ops.sh       # 服务重启、健康检查、状态总览、日志查看（Supervisor + systemctl）
      backup-rollback.sh   # 备份与回滚
      deploy-dispatch.sh   # 部署调度逻辑：批量部署、排序、摘要
      interactive.sh       # 交互式菜单与部署/回滚选择
    kind/                  # 各类型部署实现
      deploy-kinds.sh      # frontend/python/java 部署函数（宝塔/旧链路双模式）
    channels/              # 部署通道层（kind × channel 矩阵，契约 CHANNEL-CONTRACT.md；
                           # 各通道依赖包清单 CHANNEL-DEPENDENCIES.md）
      registry.sh          # 通道注册器：DEPLOY_CHANNEL 解析（兼容 BAOTA_MODE）+ 唯一加载 + 动词断言
      baota.sh             # 宝塔通道（面板 API + supervisor；统一动词层）
      baota-api.py         # 宝塔面板 API 客户端（HTTP 签名 + 本机直调）
      native.sh            # 原生通道（systemd；★冻结维护）
      native-nginx.sh      # 宿主 nginx 路由后端（native/docker 共用；不是通道）
      docker.sh            # docker 通道（容器统一维护 + 宿主 nginx 收口）
    ops/                   # 一次性运维脚本（服务器初始化、证书、组网、日志、WSL 工具）
      01-cleanup-server.sh    # Phase 1: Docker + 系统冲突清理
      lib-clear-conflicts.sh  # 系统冲突清理子模块（被 01 调用，也可单独跑）
      02-install-baota.sh     # Phase 2: 安装宝塔面板（输出手动安装组件指引）
      03-check-components.sh  # Phase 3: 检查宝塔组件是否全部安装完成（含 Supervisor）
      04-setup-server.sh      # Phase 4: 创建数据库和目录（开头调用 03-check）
      05-setup-supervisor.sh  # Phase 4b: Supervisor 进程守护 + 基础设施开机自启
      06-fix-ssl-cert.sh      # 证书修复（acme.sh + 四路同步）
      07-clone-source-data.sh # 源数据克隆
      08-cleanup-baota.sh     # 宝塔部署清场（通道切换/恢复初始状态；与 01 对位）
      sync-mt5.sh             # MT5 五表同步（C 服务器 cron）
      log-audit.sh / log-hygiene.sh / setup-wireguard.sh
      wsl-*.ps1 / wsl-autostart.sh
    tools/                 # 工具脚本（探针与生成器）
      detect-status.sh     # 部署进度检测
      generate-nginx.py    # Nginx 配置生成器
      audit_seed_vs_schema.py  # 数据库列 vs seed 覆盖审计
  assets/                  # 配置资产模板（.env.example、systemd service、wireguard）
  project-configs/         # 项目配置 SSOT（TOML 格式）
    _shared.toml           # 跨项目共享默认值
    <name>/project.toml    # 单项目配置
    PROJECT-TOML-GUIDE.md  # project.toml 配置指南（字段详解 + 完整示例）
    KINDS-CONTRACT.md      # 双端行为契约（改脚本前必读）
  dist/                    # 构建产物（gitignore，由 build.ps1 生成；与 scripts/ 同构分层）
  docs/                    # 文档
  tests/                   # 测试脚本
    run-all.sh             # L1 本地快速回归（语法/配置/CRLF/依赖上界/密码防线，8 项）
    golden-path-vm.sh      # L2 黄金链路（VM：清场→从零部署→8 类断言）
  deploy.env*              # 环境配置（gitignore）
```

## 核心数据流

```
project-configs/*.toml → core/config_loader.py (运行时直接读取)
                           ↓
build.ps1 → pack.ps1 → dist/packages/*.tar.gz
    ↓
build.ps1 → Copy-DeployAssets → dist/ (自包含部署包，与 scripts/ 同构分层)
    ↓
scp dist/ → server:/www/wwwroot/project/uploads/
    ↓
bash deploy.sh → core/ + kind/ + channel/ → 部署/回滚/状态/日志
```

## Non-Negotiables

1. **密码只放 `deploy.env*`**，禁止写进脚本或文档或 Git。
2. **项目配置走 TOML**（`project-configs/`），不硬编码到脚本。
3. **`dist/` 是自包含的**：服务器上 `bash deploy.sh` 无需源码目录；dist 与 scripts/ **同构分层**（core/ kind/ channel/ tools/ ops/ assets/），入口 deploy.sh 在 dist 根。
4. **分层模块只被 source，不直接执行**；依赖方向 = deploy.sh → core/ → kind/ → channel/。
5. **`deploy.sh` 主文件 ≤ 500 行**：功能函数拆到分层模块，主文件只保留参数解析、交互菜单、主入口。
6. **Shell 选择**：打包/构建用 Windows PowerShell；部署/测试/运维用 WSL Ubuntu Bash。
7. **部署通道隔离**：宝塔原生（BAOTA_MODE=1，python/java/前端三类）与旧链路（systemd+nginx）二选一；docker 与宝塔不共存，不做混合模式。
8. **最小 diff**：每次改动聚焦一个关注点，不混合无关变更。
9. **不主动 commit**：除非用户明确要求。

## 关键文件索引

| 你想… | 看哪里 |
|---|---|
| 加新项目 | `project-configs/<name>/project.toml` + `assets/<name>.env.example` |
| 加新 Python 后端 | `project.toml` 配 baota_project/baota_port/baota_cmd（宝塔通道）或 `deploy_hook`（旧链路） |
| 回归测试 | L1: `bash tests/run-all.sh`；L2: `ssh vm "bash -s" -- < tests/golden-path-vm.sh` |
| 改部署逻辑 | `scripts/kind/deploy-kinds.sh`（按 kind 分发） |
| 改备份/回滚 | `scripts/core/backup-rollback.sh` |
| 改宝塔通道 | `scripts/channel/baota.sh` + `scripts/channel/baota_api.py` |
| 改 Nginx 生成 | `scripts/tools/generate-nginx.py`（调用方 `scripts/channel/nginx.sh`） |
| 跨机互联（Redis/PG/新服务） | `scripts/ops/setup-wireguard.sh` + `docs/guide/multi-server-interconnect.md` |
| 改 preflight 检查 | `scripts/core/preflight.sh` |
| 改打包逻辑 | `scripts/pack.ps1` |
| 查部署文档 | `docs/guide/` 下按场景选择 |
| 查 project.toml 字段 | `project-configs/PROJECT-TOML-GUIDE.md` |
| 查排障历史 | `docs/deploy-troubleshooting-history.md` |

## 架构决策

### deploy.sh 模块化拆分（2026-08-12，更新 2026-08-13）

`deploy.sh` 从 2107 行拆分为 472 行主文件 + 8 个 lib 模块：
- 主文件保留：帮助、参数解析、环境加载、主入口逻辑（472 行）
- `lib/common.sh`：颜色、日志、CRLF、新鲜度（101 行）
- `lib/preflight.sh`：pre-flight 检查（163 行）
- `lib/service-ops.sh`：服务操作（203 行）
- `lib/backup-rollback.sh`：备份回滚（247 行）
- `lib/nginx.sh`：Nginx（192 行）
- `lib/deploy-kinds.sh`：5 种部署函数（557 行）
- `lib/deploy-dispatch.sh`：部署调度逻辑：批量部署、排序、摘要（122 行）
- `lib/interactive.sh`：交互式菜单与部署/回滚选择（197 行）
- `lib/load-deploy-env.sh`：环境变量加载（89 行）
- `lib/load-projects.sh`：项目清单加载（45 行）

### Python 部署钩子泛化（2026-08-27，更新 2026-08-27）

`deploy-python.sh` 是通用 Python/FastAPI 部署钩子，不写死任何项目名：
- 组件身份由 `COMPONENT_ID` 环境变量注入（`deploy.sh` 调用时从 `project.toml` 自动传入）
- 项目专有值（`SERVICES` / `POST_DEPLOY_CHECK_PATH` / `WEB_PATH`）由 `project.toml` → `config_loader.py` → `deploy.sh` → 环境变量注入
- 脚本零项目名硬编码，新增 Python 后端只需在 `project.toml` 指向 `deploy-python.sh` + 配 `configs/<id>.env.example`
- 测试：`tests/test-hook-generalization.sh`（12 场景）

### 三通道重构：kind × channel 矩阵（2026-10-22）

`if baota_enabled` 分支从 deploy-kinds.sh 全部移除，通道成为一等公民：
- `channel/registry.sh`：解析 DEPLOY_CHANNEL（兼容 BAOTA_MODE）→ source 恰好
  一个通道文件 → 12 个统一动词逐一断言（缺即 fail-fast）；
- 统一动词（CHANNEL-CONTRACT.md §3）：`channel_{name,supported_kinds,
  wants_host_venv,routing_sync,frontend_prepare/preserve/restore/finalize,
  python_install/restart,java_install/restart}`；
- `kind/deploy-kinds.sh` = 与通道无关的公共流程（找包→备份→解压→.env→
  依赖→健康检查闭环），只在分歧点调动词；
- `--channel=native|baota|docker` 命令行覆盖；docker 通道 MVP（python 支持）。
- L1 第 9 项 = 通道动词完备性审计（三通道逐一核对）。

### 瘦身（2026-10-22）

- 移除 go/nodejs 部署与打包实现（deploy-kinds.sh 669→455 行、pack.ps1 1067→702 行）；
  fullstack-demo 的 go/nodejs 组件段注释化保留样例
- 旧链路 channel/nginx.sh 标注冻结（仅供 A/B 应急，迁移后删除）
- 测试重做：L1 加 CRLF 防线、Python 依赖上界审计（mcp 2.x 事故的类级防御）；
  L2 黄金链路测试落 VM（清场→部署→断言）
- 待办：deploy-python.sh（983 行）退役合并进 deploy-kinds（financial deploy_hook 迁移）

### 目录分层（2026-08-12，二次重组 2026-10-22）

`scripts/` 分层结构（lib/ 大杂烩时代终结）：
- `scripts/`：入口与构建（deploy.sh、build.ps1、pack.ps1、deploy-python.sh、_ps-common.ps1、preclean-dist.ps1）
- `scripts/core/`：部署主链路装载层（8 个 .sh + config_loader.py）
- `scripts/kind/`：各类型部署实现（deploy-kinds.sh）
- `scripts/channel/`：部署通道（宝塔原生 baota.* / 旧链路 nginx.sh，BAOTA_MODE 切换）
- `scripts/ops/`：一次性运维脚本（编号系列 + 证书/组网/日志/WSL 工具）
- `scripts/tools/`：探针与生成器（detect-status、generate-nginx、audit_seed_vs_schema）
- `configs/ → assets/`：与 project-configs 消歧义（assets=部署资产模板）
- `dist/` 与 `scripts/` **同构分层**（build.ps1 负责映射），入口 deploy.sh 在 dist 根
