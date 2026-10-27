# project.toml 配置指南（v2 意图模型 · 新项目接入必读）

> 配置 SSOT：`project-configs/<项目>/project.toml`。
> **新项目接入 = 新增一个 TOML +（如有后端）env/systemd 资产，零脚本改动。**
> 意图模型只声明 **routes / process / companions**，无任何通道字眼；
> 通道（baota / native / docker）在部署时由 `DEPLOY_CHANNEL` 决定，
> 各通道把同一份意图翻译成自己的落地对象。
> 通道契约见 [CHANNEL-CONTRACT.md](CHANNEL-CONTRACT.md)，
> kind 打包契约见 [KINDS-CONTRACT.md](KINDS-CONTRACT.md)，
> 依赖清单见 [CHANNEL-DEPENDENCIES.md](CHANNEL-DEPENDENCIES.md)。

## 架构设计

```
project-configs/<name>/project.toml   (SSOT, 人编辑 —— 唯一配置源)
        ↓ scripts/core/config_loader.py (运行时直接读取，无 projects.json 硬编码)
        ↓                                 ↓
scripts/build.ps1 (本地打包)        scripts/deploy.sh (服务器部署)
        ↓                                 ↓
   kind 层：做什么（找包→备份→解压→.env→依赖→健康门，公共流程）
   channel 层：落在哪、怎么跑（baota=面板对象 / native=systemd+nginx / docker=容器+宿主nginx）
```

- **一个配置源**：TOML 是唯一 SSOT；`load-projects.sh` 经 `config_loader.py`
  直读 `project-configs/*.toml`（无硬编码项目清单）
- **一个打包器 / 一个部署器**：两端都经 `config_loader.py` 读同一份 TOML，无项目硬编码分支
- **新增项目**：只需在 `project-configs/` 下新建 `<项目名>/project.toml`

## kind × channel 支持矩阵

部署 = **kind × channel**。kind 决定"做什么"，channel 决定"落在哪、怎么跑"。

| kind | 技术栈 | 打包流程 | baota | native | docker |
|------|--------|----------|:-----:|:------:|:------:|
| `frontend` | Vue / React / Svelte… | pnpm/npm/yarn build → dist tar.gz | ✅ HTML 站点 | ✅ | ✅（宿主目录，同 native） |
| `python` | FastAPI / Flask | 源码 + includes → tar.gz | ✅ Python 项目 | ✅ systemd | ✅（容器，MVP） |
| `java` | Spring Boot | mvn/gradle → JAR tar.gz | ✅ Java 项目 | ✅ systemd | ❌ |
| `go` | Gin / Echo… | go build → 二进制 | ❌（扩展位） | ❌（扩展位） | ❌ |
| `nodejs` | Express / NestJS | 源码 + npm ci | ❌（扩展位） | ❌（扩展位） | ❌ |

> 同机单通道（baota/docker 互斥，registry 强制）；env 键 `DEPLOY_CHANNEL`
> 选择通道，兼容旧 `BAOTA_MODE=1` → baota。

## 完整配置示例（带注释，来自真实项目）

```toml
# ═══════════════════════════════════════════════════════════════
# project-configs/my-project/project.toml — 项目说明
# ═══════════════════════════════════════════════════════════════

# ── 项目元信息 ──
[project]
id = "my-project"                        # 项目 ID（build.ps1 / deploy.sh 参数）
display_name = "我的项目（前端 + 后端）"

# 随包上传的部署资产（相对 deploy 根；native 通道的 systemd 模板放这里）
key_files = [
    "assets/systemd/my-backend.service",
]

# ── 部署行为 ──
[deploy]
backup_retention = 5                      # 保留最近几份备份
health_timeout = 30                       # 健康检查超时（秒）

# ═══════════════════════════════════════════════════════════════
# 组件 1：前端
# ═══════════════════════════════════════════════════════════════
[[components]]
id = "my-web"                             # 组件 ID（唯一）
kind = "frontend"                         # frontend | python | java
display_name = "前端"
source_path = "my-project/web"            # 源码路径（相对 WORKSPACE_ROOT）
public_url = "/"                          # 对外 URL 前缀（根站点用 /）
deploy_path = "my-project/web/dist"       # 服务器路径（相对 PROJECT_BASE）
routes = [
    { path = "/", type = "root", spa = true },        # 根站点
    # { path = "/app/", type = "static", spa = true } # 子路径站点（vite 需配 base）
]

  [components.build]
  package_manager = "pnpm"                # pnpm | npm | yarn
  build_script = "build"                  # package.json scripts 命令名
  dist_dir = "dist"                       # 构建产物目录
  artifact = "my-web-dist.tar.gz"         # 打包产物文件名
  # env_file = "assets/my-web.env"      # 构建期 .env（VITE_* 等，可选）

# ═══════════════════════════════════════════════════════════════
# 组件 2：后端（Python）
# ═══════════════════════════════════════════════════════════════
[[components]]
id = "my-backend"
kind = "python"
display_name = "后端 API"
source_path = "my-project/backend"        # 源码路径（相对 WORKSPACE_ROOT）
deploy_path = "my-project/backend/package"# 服务器路径（相对 PROJECT_BASE，★全局唯一）
health_url = "http://127.0.0.1:5000/api/health"   # 部署后健康检查（服务器内网地址）
post_deploy_check_path = "/api/navigation/menu"   # 业务级检查（可选）

# ── 路由意图（★ v2：替代旧 nginx.locations）──
routes = [
    { path = "/api/ws", type = "websocket", target = "http://127.0.0.1:5000/api/ws" },
    { path = "/api/",   type = "proxy",     target = "http://127.0.0.1:5000/api/" },
]

# ── 伴随服务（★必须写在 [components.process] 段之前 —— TOML 表序约束，
#    进入子表后键就归属该子表了）──
# 纯名字 = 宿主守护对象（宝塔 supervisor 程序 / systemd 同名单元）；
# 对象形式 = 补充 docker 容器化所需意图（MVP 阶段 docker companions 预留）
companions = [
    "my-worker",
    # { name = "my-mcp", cmd = "python -m my_mcp.server", port = 7800 },
]

# ── 主进程意图（★ v2 核心：通道据此翻译成各自的运行载体）──
[components.process]
port = 5000                               # 监听端口（宝塔项目/docker 发布端口）
cmd = ".venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 5000"
                                          # 启动命令（相对 deploy_path，
                                          # 通道负责拼绝对路径；容器内绑 0.0.0.0）
migrate = "alembic upgrade head"          # 部署时迁移命令（可选）

  # ── 打包配置：只打包服务器需要的 ──
  [components.pack]
  package_mode = "app-package"            # source-tar（归档根）/ app-package（进 package/）
  artifact_pattern = "my-backend-*.tar.gz"
  include_files = [                       # 额外打包的部署资产
      "assets/my-backend.env.example",
  ]
  include_env = ["assets/my-backend.env"] # ★安全白名单：仅列出的 .env 才允许进包
  # extra_exclude_dirs = ["custom_dir"]  # 追加排除（继承 _shared.toml）

  # 附带额外源码目录（如 MCP Server），复制到归档指定子目录
  # [[components.pack.extra_source]]
  # path = "my-project/mcp_server"
  # dest = "mcp_server"                   # 归档内 → package/mcp_server/
```

## 意图 → 通道翻译表

同一份 TOML，三个通道各自的落地对象：

| TOML 意图 | baota（主力） | native（冻结） | docker（MVP） |
|-----------|---------------|----------------|----------------|
| `routes(type=root/static)` | 宝塔 HTML 站点（conf=`vhost/nginx/html_<站点名>.conf`，必须带前缀） | generate-nginx location → default.conf | 宿主 nginx 静态（同 native） |
| `routes(type=proxy/websocket)` | 面板原生反代 `CreateProxy`（conf 落 `vhost/nginx/proxy/<站点>/`） | generate-nginx proxy 块 | 宿主 nginx → 容器（host 网络，端口即宿主端口） |
| `process(port, cmd)` | 宝塔 Python/Java 项目（名=组件 id，cmd 自动拼 deploy_path 绝对路径） | systemd 单元 `<id>.service`（模板 assets/systemd/） | Dockerfile + compose（端口发布绑 127.0.0.1） |
| `process(migrate)` | 部署时 venv 内执行 | 同左 | 预留（当前手动） |
| `companions` | 宝塔 supervisor 程序 | systemd 单元 `<name>.service` | **预留** |
| `deploy_hook`（legacy） | 支持 | 支持 | 跳过（走默认流程） |

## 字段速查

### `[project]`

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `id` | string | ✅ | 项目唯一标识（deploy.sh 命令行参数） |
| `display_name` | string | ✅ | 人类可读名称 |
| `key_files` | array | ❌ | 随包上传的部署资产（native systemd 模板等） |
| `enabled` | boolean | ❌ | `false` = 整项目下线（模板/演示项目用；fullstack-demo 默认 false，d40862d） |

### `[deploy]`

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `backup_retention` | 5 | 保留备份数 |
| `health_timeout` | 30 | 健康检查超时秒数 |

### `[[components]]`

| 字段 | 必填 | 说明 |
|------|------|------|
| `id` | ✅ | 组件唯一标识 |
| `kind` | ✅ | `frontend` / `python` / `java`（go/nodejs 为打包层扩展位，通道未覆盖） |
| `display_name` | ✅ | 日志显示名 |
| `source_path` | ✅ | 源码路径（相对 WORKSPACE_ROOT） |
| `deploy_path` | ✅ | 服务器路径（相对 PROJECT_BASE；**python 部署会清空此目录，必须全局唯一**） |
| `public_url` | ❌ | 对外 URL 前缀（前端用） |
| `health_url` | ❌ | 部署后健康检查 URL（`http://127.0.0.1:<port>/...`） |
| `post_deploy_check_path` | ❌ | 业务级检查路径 |
| `web_path` | ❌ | 子路径前端标识（如 `/financial`） |
| `deploy_hook` | ❌ | legacy 自定义部署脚本（迁移完成后退役） |
| `routes` | ❌ | 路由意图数组，见下 |

### `routes`（v2 路由意图）

| 字段 | 说明 |
|------|------|
| `path` | location 路径 |
| `type` | `root` / `static`（静态，前端）/ `proxy` / `websocket`（后端） |
| `target` | proxy/websocket 的后端地址（`http://127.0.0.1:<port>/...`） |
| `spa` | static/root 的 SPA 404 → index.html |

### `[components.process]`（v2 主进程意图，python/java）

| 字段 | 说明 |
|------|------|
| `port` | 监听端口 |
| `cmd` | 启动命令（相对 deploy_path，通道拼绝对路径；容器内需绑 0.0.0.0） |
| `migrate` | 部署时迁移命令（可选，如 `alembic upgrade head`） |

### `companions`（伴随服务意图）

- 纯字符串：`"my-worker"` —— baota=supervisor 程序 / native=systemd 同名单元
- 对象：`{ name, cmd, port }` —— 补充 docker 容器化所需意图（当前 docker companions 预留）
- ⚠️ **必须写在 `[components.process]` 等子表段之前**（TOML 表序约束）

### `[components.build]` (frontend / java)

| 字段 | 适用 kind | 说明 |
|------|-----------|------|
| `package_manager` | frontend | `pnpm` / `npm` / `yarn` |
| `build_script` | frontend | package.json scripts 中的命令名 |
| `dist_dir` | frontend | 构建产物目录 |
| `artifact` | frontend | 打包产物文件名 |
| `env_file` | frontend | 构建期 .env（VITE_* 等） |
| `build_tool` / `jar_dir` / `jar_pattern` | java | maven/gradle、JAR 目录与匹配模式 |

### `[components.pack]` (python / nodejs)

| 字段 | 说明 |
|------|------|
| `package_mode` | `source-tar`（源码在归档根）/ `app-package`（源码进 package/） |
| `artifact_pattern` | 打包产物文件名模式 |
| `include_files` | 额外打包文件列表 |
| `include_env` | ★安全白名单：允许进包的 .env（默认全排除） |
| `extra_exclude_dirs` / `extra_exclude_files` | 追加排除（继承 `_shared.toml`） |

### `[[components.pack.extra_source]]`

| 字段 | 说明 |
|------|------|
| `path` | 额外源码目录路径（相对 WORKSPACE_ROOT，如 MCP Server） |
| `dest` | 归档内目标子目录名（部署时自动 pip install，见 KINDS-CONTRACT） |

## .env 模板占位符

首次部署时由部署脚本从 `.env.example` 渲染（值来自 `deploy.env.*`）：

| 占位符 | 替换为 |
|--------|--------|
| `__PG_PASSWORD__` | `deploy.env` → `PG_PASSWORD` |
| `__REDIS_PASSWORD__` | `deploy.env` → `REDIS_PASSWORD` |
| `__SERVER_IP__` | 命令行 `--ip` 或 127.0.0.1 |
| `__FRONTEND_URL__` | `deploy.env` → `FRONTEND_URL` |
| `__SECRET_KEY__` | 随机生成 |
| `__ADMIN_PASSWORD__` | `deploy.env` → `ADMIN_PASSWORD` |
| `__MCP_AGENT_TOKEN__`（systemd 模板） | `deploy.env` → `MCP_AGENT_TOKEN` |

## 新项目接入 SOP（零脚本改动）

1. **放源码**：工作区放好项目源码（`source_path` 指向它）
2. **写 TOML**：`project-configs/<项目名>/project.toml`（复制上文模板或现成的
   financial / deepquant / official-site 改）
3. **部署资产**（如有后端）：
   - `assets/<项目>.env.example` 模板（真实密码只活在 `deploy.env.*`）
   - native 通道 systemd 单元模板 → `assets/systemd/<服务名>.service`
4. **通道字段**：无需配置——通道在部署时由 `DEPLOY_CHANNEL` 决定；
   只要 TOML 把 `routes` / `process` / `companions` 意图写清楚，三通道通用
5. **验证打包**：`.\scripts\build.ps1 <项目名>`
6. **部署**：`bash deploy.sh <项目名|组件ID> --target=server-X --yes`
7. **自检**：宝塔机跑 `BASE_DOMAIN=<域名> bash scripts/tools/check-deploy.sh`（40 项）；
   面板上确认站点/项目/反代原生可见可管理

## ⚠️ 注意事项（历史踩坑，别再犯）

- **deploy_path 必须全局唯一**：python 部署先清空 deploy_path 再解压，两个组件共用会互相覆盖
  （2026-08-24 deepquant-mcp 覆盖 backend 静默事故）。辅助服务用 `pack.extra_source`
  打进主组件的包，**不要**另开组件（反例详见本文件 git 历史）。
- **companions 写在 process 段之前**：TOML 一旦进入 `[components.process]` 子表，
  之后的键都归属该子表。
- **WebSocket 路径**：`routes` 里的 websocket path 必须与前端实际连接路径一致。
- **.env 安全**：默认全排除，仅 `include_env` 白名单放行；真实密码只活在 `deploy.env.*`。
- **子路径前端**：vite 需配 `base = '/<子路径>/'`（参考 official-site 的 `/qd/`）。
- **共享 venv（`venv_shared`）**：只在两个组件确实共用同一 deploy_path 时有意义——
  而这正是要避免的配置，请勿使用。
- **health_url 用内网地址**：`http://127.0.0.1:<port>/<path>`。
