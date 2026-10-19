# KINDS-CONTRACT — 五种 kind 的双端行为契约

> **用途**：工具箱存在两套 kind 实现——本地打包（`scripts/pack.ps1`，PowerShell）与服务器部署（`scripts/lib/deploy-kinds.sh`，Bash）。
> **改任何一端的 kind 行为前，先读本文；改完后必须双端同步，并在本文勾掉核对清单。**
> 配置 SSOT 是 `project-configs/<项目>/project.toml`，本文只描述"脚本对每个 kind 做什么"。

## frontend

| 端 | 行为 |
|----|------|
| 打包（pack.ps1） | 按 `package_manager`（pnpm/npm/yarn）在 `source_path` 执行 `build_script` → 打包 `dist_dir` → `build.artifact` 命名的 tar.gz |
| 部署（deploy-kinds.sh） | 备份当前 dist → 清空 `deploy_path` → 解压到 `deploy_path` → `nginx_reload=true` 时同步 nginx（批量部署时延迟到全部前端完成后统一 reload） |
| 双端共用字段 | `source_path` / `deploy_path` / `build.artifact` / `nginx_reload` |

## python

| 端 | 行为 |
|----|------|
| 打包（pack.ps1） | 两种 `package_mode`：**app-package**=源码进归档 `package/` 子目录（financial-api）；**source-tar**=源码在归档根（deepquant-backend，为了让 MCP `extra_source` 搭车）。排除列表取 `_shared.toml [python_defaults]` + `extra_exclude_*`；`.env` 全排除，仅 `include_env` 白名单放行 |
| 部署（deploy-kinds.sh） | 走 `deploy_hook`（默认 `scripts/deploy-python.sh`）：**清空 pkg_dir（保留 .env/.venv/logs/data）** → 解压 → 渲染 .env 模板占位符（`__PG_PASSWORD__` 等，值来自 deploy.env）→ venv + pip → **MCP 自动检测**（有 `mcp_server/` 子目录就 pip install 进共享 venv）→ 按需迁移 → 重启 `services` 列表 |
| 双端共用字段 | `package_mode` / `include_files` / `include_env` / `extra_source` / `health_url` / `services` / `post_deploy_check_path` |

## java

| 端 | 行为 |
|----|------|
| 打包（pack.ps1） | 按 `build_tool`（maven/gradle）构建 → 只打包 `jar_dir` 里匹配 `jar_pattern` 的 JAR/WAR + configs（**不打包源码**） |
| 部署（deploy-kinds.sh） | 解压到 `deploy_path` → 重启 systemd/supervisor 服务 |
| 双端共用字段 | `jar_dir` / `jar_pattern` / `include_env` / `services` |

## go

| 端 | 行为 |
|----|------|
| 打包（pack.ps1） | 执行 `build_command`（交叉编译 `GOOS=linux GOARCH=amd64`）→ 打包 `binary_name` + configs（**不打包源码**） |
| 部署（deploy-kinds.sh） | 解压到 `deploy_path` → chmod +x → 重启服务 |
| 双端共用字段 | `build_command` / `binary_name` / `include_env` / `services` |

## nodejs

| 端 | 行为 |
|----|------|
| 打包（pack.ps1） | 可选 `build_script`（NestJS 需 TS→JS）→ 源码复制（排除 `[nodejs_defaults]`，**不含 node_modules**） |
| 部署（deploy-kinds.sh） | 解压到 `deploy_path` → 服务器端 `npm ci --production` → 重启服务 |
| 双端共用字段 | `build_script` / `extra_exclude_dirs` / `include_env` / `services` |

## 跨 kind 的铁律（双端都要遵守）

1. **同一 `deploy_path` 禁止给两个组件共用**——python 部署先清空 pkg_dir，后部署者会抹掉先部署者（2026-08-24 deepquant-mcp 覆盖 backend 事故，见 deepquant/project.toml 头注记）。
2. **`.env` 默认全排除**，唯一放行通道是 `include_env` 白名单；真实密码只活在 `deploy.env*`，部署时占位符渲染。
3. **python 清空保留名单**：`.env` `.venv` `logs` `data`——回滚侧（backup-rollback.sh）的 find 排除必须与此一致，否则回滚后服务起不来。
4. **备份内容按 kind 区分**：frontend 只备 dist；python/java/go/nodejs 备 pkg_dir 但**不含 .venv**（backup_frontend / backup_backend 分工）。
5. **健康检查**（`health_check`，3 次尝试）失败返回 1：部署路径裸调用（结果只影响日志语义），**回滚路径显式捕获**——回滚后健康检查失败 = 整次回滚计为失败。

## 双端同步核对清单（改 kind 行为后逐项勾）

- [ ] pack.ps1（PowerShell 端）已改并实测打包
- [ ] deploy-kinds.sh / deploy-python.sh（Bash 端）已改
- [ ] 两端读取的字段名一致（`config_loader.py` 的 `_KEY_MAP` snake→camel 映射是否需要新增）
- [ ] `tests/run-all.sh` 全绿
- [ ] 真实部署一次验证（dist/lib 会随包同步到服务器，无需手动 scp lib）
