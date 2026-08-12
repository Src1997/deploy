# project.toml 配置指南

> 通用模板：以 QuantDinger 项目为例，详解 `project.toml` 各字段含义和配置方法。
> 新项目只需复制 `project-configs/<name>/` 并修改，**无需改任何脚本**。

## 架构设计

```
project-configs/*.toml (SSOT, 人编辑)
    ↓ sync-manifest.py
projects.json (manifest, 机器读)
    ↓                     ↓
pack.ps1 (打包)        deploy.sh (部署)
```

- **一个配置源**：`project-configs/<name>/project.toml` 是唯一 SSOT
- **一个打包器**：`pack.ps1` 读 `projects.json`，所有项目共用
- **一个部署器**：`deploy.sh` 读 `projects.json`，所有项目共用（无项目硬编码分支）
- **新增项目**：只需在 `project-configs/` 下新建一个 `project.toml`

## 支持的组件类型

| `kind` | 技术栈 | 打包流程 |
|--------|--------|----------|
| `frontend` | Vue / React / Angular / Svelte | `pnpm/npm/yarn build` → `dist/` tar.gz |
| `python` | Python (FastAPI / Flask) | 源码 + includes → tar.gz |
| `java` | Java (Spring Boot) | `mvn/gradle build` → JAR/WAR tar.gz |
| `go` | Go (Gin / Echo / Fiber) | `go build` → 二进制 tar.gz |
| `nodejs` | Node.js (Express / NestJS) | 源码 + `npm ci --production` |

## 完整配置示例（带注释）

```toml
# ═══════════════════════════════════════════════════════════════
# project-configs/my-project/project.toml — 项目说明
# ═══════════════════════════════════════════════════════════════

# ── 项目元信息 ──
[project]
id = "my-project"                        # 项目 ID（deploy.sh 命令行参数）
display_name = "我的项目（前端 + 后端）"

# 随包上传的部署资产（相对 deploy 根路径）
# systemd 服务模板、env 模板等
key_files = [
    "configs/systemd/my-backend.service",
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
kind = "frontend"                         # frontend | python | java | go | nodejs
display_name = "前端"
source_path = "my-project/web"            # 源码路径（相对 WORKSPACE_ROOT）
public_url = "/app/"                      # Nginx 对外 URL 前缀
deploy_path = "my-project/web/dist"        # 服务器路径（相对 PROJECT_BASE）
nginx_reload = true                       # 部署后是否 reload nginx

  [components.build]
  package_manager = "pnpm"                # pnpm | npm | yarn
  build_script = "build"                  # package.json scripts 命令名
  dist_dir = "dist"                       # 构建产物目录
  artifact = "my-web-dist.tar.gz"         # 打包产物文件名
  # env_file = "configs/my-web.env"      # 构建期 .env（VITE_* 等，可选）

  [[components.nginx.locations]]
  path = "/app/"                          # Nginx location 路径
  type = "static"                         # static | proxy | websocket
  spa_fallback = true                     # SPA 404 → index.html

# ═══════════════════════════════════════════════════════════════
# 组件 2：后端（Python）
# ═══════════════════════════════════════════════════════════════
[[components]]
id = "my-backend"
kind = "python"
display_name = "后端 API"
source_path = "my-project/backend"
deploy_path = "my-project/backend/package"
nginx_reload = false
health_url = "http://127.0.0.1:5000/api/health"  # 部署后健康检查
services = [                              # 部署后重启的 systemd 服务
    "my-backend",
]

  # ── Nginx 路由：API 代理 ──
  [[components.nginx.locations]]
  path = "/app/api/"
  type = "proxy"
  proxy_target = "http://127.0.0.1:5000"
  proxy_path = "/api/"                    # 转发路径（去掉 /app 前缀）

  # ── Nginx 路由：WebSocket ──
  # 路径必须匹配前端实际连接路径
  [[components.nginx.locations]]
  path = "/app/ws/"
  type = "websocket"
  proxy_target = "http://127.0.0.1:5000"
  proxy_path = "/ws/"

  # ── 打包配置 ──
  [components.pack]
  package_mode = "app-package"            # source-tar | app-package
  artifact_pattern = "my-backend-*.tar.gz"
  include_files = [                       # 额外打包的部署资产
      "configs/my-backend.env.example",
  ]
  # 安全白名单：仅此处列出的 .env 才允许进包
  include_env = ["configs/my-backend.env"]
  # extra_exclude_dirs = ["custom_dir"]   # 追加排除（继承 _shared.toml）

  # 附带额外源码目录（如 MCP Server），复制到归档根下 mcp_server/
  # [[components.pack.extra_source]]
  # path = "my-project/mcp_server"
  # dest = "mcp_server"

# ═══════════════════════════════════════════════════════════════
# 组件 3：共享 venv 的辅助服务（如 MCP Server）
# ═══════════════════════════════════════════════════════════════
# [[components]]
# id = "my-mcp"
# kind = "python"
# display_name = "MCP Server"
# source_path = "my-project/mcp_server"
# deploy_path = "my-project/backend/package"  # 与 backend 共享同一目录和 venv
# nginx_reload = false
# health_url = "http://127.0.0.1:7800/sse"
# venv_shared = true                       # 共享 venv（不创建新的，检查存在性）
# services = [
#     "my-mcp",
# ]
#
#   [components.pack]
#   package_mode = "source-tar"
#   artifact_pattern = "my-mcp-*.tar.gz"
```

## 字段速查

### `[project]`

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `id` | string | ✅ | 项目唯一标识 |
| `display_name` | string | ✅ | 人类可读名称 |
| `key_files` | array | ❌ | 随包上传的部署资产路径 |

### `[deploy]`

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `backup_retention` | 5 | 保留备份数 |
| `health_timeout` | 30 | 健康检查超时秒数 |

### `[[components]]`

| 字段 | 必填 | 说明 |
|------|------|------|
| `id` | ✅ | 组件唯一标识 |
| `kind` | ✅ | `frontend` / `python` / `java` / `go` / `nodejs` |
| `display_name` | ✅ | 日志显示名 |
| `source_path` | ✅ | 源码路径（相对 WORKSPACE_ROOT） |
| `deploy_path` | ✅ | 服务器路径（相对 PROJECT_BASE） |
| `public_url` | ❌ | Nginx 对外 URL 前缀（前端用） |
| `nginx_reload` | ❌ | 部署后是否 reload nginx |
| `health_url` | ❌ | 部署后 HTTP 健康检查 URL |
| `services` | ❌ | 部署后重启的 systemd 服务列表 |
| `deploy_hook` | ❌ | 自定义部署脚本路径 |
| `venv_shared` | ❌ | 共享 venv 模式（不创建新 venv，检查存在性） |

### `[components.build]` (frontend / java / go / nodejs)

| 字段 | 适用 kind | 说明 |
|------|-----------|------|
| `package_manager` | frontend | `pnpm` / `npm` / `yarn` |
| `build_script` | frontend | package.json scripts 中的命令名 |
| `dist_dir` | frontend | 构建产物目录 |
| `artifact` | frontend | 打包产物文件名 |
| `env_file` | frontend | 构建期 .env（VITE_* 等） |

### `[components.pack]` (python / nodejs)

| 字段 | 说明 |
|------|------|
| `package_mode` | `source-tar`（源码在归档根）/ `app-package`（源码进 package/） |
| `artifact_pattern` | 打包产物文件名模式 |
| `include_files` | 额外打包文件列表 |
| `include_env` | 安全白名单：允许进包的 .env 文件 |
| `extra_exclude_dirs` | 追加排除目录（继承 `_shared.toml`） |
| `extra_exclude_files` | 追加排除文件 |

### `[[components.pack.extra_source]]`

| 字段 | 说明 |
|------|------|
| `path` | 额外源码目录路径（相对 WORKSPACE_ROOT） |
| `dest` | 归档内目标子目录名 |

### `[[components.nginx.locations]]`

| 字段 | 说明 |
|------|------|
| `path` | Nginx location 路径 |
| `type` | `static` / `proxy` / `websocket` |
| `proxy_target` | 后端监听地址（proxy/websocket） |
| `proxy_path` | 转发路径（proxy/websocket） |
| `spa_fallback` | SPA 404 → index.html（static） |

## deploy.sh 通用部署流程（Python）

`deploy.sh` 对所有 `kind = "python"` 组件统一执行：

1. **deployHook**（如有）：执行自定义脚本，跳过后续步骤
2. **解压**：备份 .env → 清理旧代码 → 解压 tar → 恢复 .env
3. **venv**：`venv_shared = true` 时检查存在性；否则按需创建
4. **pip install**：自动检测 `requirements.txt` 或 `pyproject.toml`
5. **MCP 自动检测**：如存在 `mcp_server/pyproject.toml`，自动安装
6. **.env 生成**：首次部署从 `.env.example` 模板渲染占位符
7. **systemd 服务**：安装/更新服务模板，渲染 `__MCP_AGENT_TOKEN__` 等占位符
8. **重启 + 健康检查**：重启服务，检查 `health_url`

## .env 模板占位符

`deploy.sh` 在首次部署时自动替换以下占位符：

| 占位符 | 替换为 | 来源 |
|--------|--------|------|
| `__PG_PASSWORD__` | PG 密码 | `deploy.env` → `PG_PASSWORD` |
| `__REDIS_PASSWORD__` | Redis 密码 | `deploy.env` → `REDIS_PASSWORD` |
| `__SERVER_IP__` | 服务器 IP | 命令行 `--ip` 或 `127.0.0.1` |
| `__FRONTEND_URL__` | 前端 URL | `deploy.env` → `FRONTEND_URL` |
| `__SECRET_KEY__` | 随机生成 | `python3 -c "import secrets; ..."` |
| `__ADMIN_PASSWORD__` | 管理员密码 | `deploy.env` → `ADMIN_PASSWORD` |

systemd 服务模板占位符：

| 占位符 | 替换为 |
|--------|--------|
| `__MCP_AGENT_TOKEN__` | `deploy.env` → `MCP_AGENT_TOKEN` |

## 新增项目步骤

1. 在工作区放好源码
2. 在 `project-configs/` 下新建 `<项目名>/project.toml`（可复制本模板修改）
3. 在 `configs/systemd/` 下创建 systemd 服务模板（如有后端）
4. 在 `configs/` 下创建 `.env.example` 模板（如有后端）
5. 运行 `.\scripts\build.ps1 <项目名>` 验证打包
6. 上传 → 服务器 `bash deploy.sh <组件ID> --yes`

## 注意事项

- **WebSocket 路径**：必须与前端实际连接路径一致（如 `/app/ws/` 而非 `/ws/`）
- **共享 venv**：`venv_shared = true` 的组件必须先部署主组件
- **.env 安全**：默认全排除，仅 `include_env` 白名单中的文件进包
- **健康检查**：`health_url` 用 `http://127.0.0.1:<port>/<path>`（服务器内网地址）
- **MCP 自动检测**：后端包内如有 `mcp_server/pyproject.toml`，deploy.sh 自动安装
