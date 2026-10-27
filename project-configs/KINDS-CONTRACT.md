# KINDS-CONTRACT — 五种 kind 的双端行为契约

> **用途**：工具箱存在两套 kind 实现——本地打包（`scripts/pack.ps1`，PowerShell）与服务器部署（`scripts/kind/deploy-kinds.sh`，Bash）。
> **改任何一端的 kind 行为前，先读本文；改完后必须双端同步，并在本文勾掉核对清单。**
> 配置 SSOT 是 `project-configs/<项目>/project.toml`，本文只描述"脚本对每个 kind 做什么"。

## frontend

| 端 | 行为 |
|----|------|
| 打包（pack.ps1） | 按 `package_manager`（pnpm/npm/yarn）在 `source_path` 执行 `build_script` → 打包 `dist_dir` → `build.artifact` 命名的 tar.gz |
| 部署（deploy-kinds.sh） | 备份当前 dist → 清空 `deploy_path` → 解压到 `deploy_path` → `nginx_reload=true` 时同步 nginx（批量部署时延迟到全部前端完成后统一 reload）；**子路径 SPA（public_url≠/）部署钩子自动重建 `dist/<sub> -> .` 自引用 symlink**（alias+try_files 的 $uri 按 root 语义解析的已知坑，d40862d） |
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

## 宝塔通道（DEPLOY_CHANNEL=baota，2026-10-20 起）

> **方向**（用户定）：所有部署成果必须在宝塔面板原生出现、原生可管理。
> **2026-10-22 起**：通道体系升级为 native/baota/docker 三通道矩阵，
> 宝塔为其中之一（主力）；选择器 `DEPLOY_CHANNEL`（兼容 BAOTA_MODE=1），
> 通道实现统一动词契约，见 **CHANNEL-CONTRACT.md**。
> **docker 通道定位（用户拍板）**：容器统一维护应用，宿主 nginx 收口路由、
> PG/Redis 基础设施宿主化——允许配套组件协作，属正式设计。
> **覆盖范围（用户 2026-10-20 定）：python / java / frontend(html) 三类。**
> ★docker 与宝塔不共存，不做混合模式。
> 未启用 BAOTA_MODE 的服务器走旧链路（systemd + generate-nginx），平滑过渡。
> Shell 侧唯一通道 = `scripts/channel/baota.sh` → `scripts/channel/baota_api.py`（面板 HTTP API，签名 md5(request_time + api.json 的 **token** 字段，单重 md5)；★不是 `key` 字段）。**不直写面板 DB、不手搓站点 nginx conf。**

| TOML 键（components 下） | 生效条件 | 行为 |
|----|----|----|
| `baota_site = "<站点名>"`（frontend） | BAOTA_MODE=1 | 站点不存在 → 原生 `AddSite`（project_type=**小写 html**，落点=deployPath）；部署目录以面板 `site-path` 为 SSOT；`.user.ini`（chattr +i 防跨站）先挪开、部署后还原加锁；**不生成/不覆盖站点 nginx conf** |
| `baota_project = "<项目名>"`（python） | BAOTA_MODE=1 | **缺失 → 从零创建**：venv 注册（本机直调 EnvironmentManager）→ `CreateProject`（pjname/port/stype/path/python_bin/project_cmd）→ `StartProject`；存在 → 原生 `RestartProject`（参数是 `name`）；跳过 systemd service 安装 |
| `baota_project = "<项目名>"`（java） | BAOTA_MODE=1 | **缺失 → 本机直调 create_project（springboot，建完即启动）**；存在 → restart_project；跳过 systemd service 安装 |
| `baota_supervisor = "<程序名 空格分隔>"`（python） | BAOTA_MODE=1 | 项目内置伴随服务（如 quantdinger-mcp）由宝塔 supervisor 插件托管，部署后 `supervisorctl restart` |
| `baota_port` / `baota_cmd`（python、java） | 创建时 | 项目端口 / 启动命令（**venv 内绝对路径**，面板进程 PATH 不含项目 venv） |
| `baota_jar` / `baota_jdk`（java） | 创建时 | jar 相对 deployPath / JDK bin 路径 |

env 键：`BAOTA_MODE` / `BAOTA_PANEL_URL`（服务器本机 → https://127.0.0.1:<端口>）/
`BAOTA_API_KEY`（api.json 的 token） / `BAOTA_PYTHON` / `BAOTA_SUPERVISORCTL`；
可选 `BAOTA_NGINX_GENERATED=1` + `NGINX_LISTEN_PORT`（生成式单 vhost 模式，见 CHANNEL-CONTRACT §5）。
面板 api.json 的 `limit_addr` 必须含 127.0.0.1（部署脚本在服务器本机调用）。

**legacy deploy_hook 在宝塔通道的护栏（0d53ec1）**：deploy-python.sh 检测 BAOTA_MODE=1 /
DEPLOY_CHANNEL=baota 时**跳过 systemd 单元安装/启用/重启**（面板项目托管主进程，svc_ctl 对
非 Supervisor 服务以警告代替 systemctl）——防双轨复发（2026-10-26 事故）。

**本机直调**：venv 注册与 Java 创建走 subprocess 调面板自带 Python 执行面板源码
（HTTP 表单传不了真 list / 需要面板内部类），仅在部署机上可用（deploy.sh 恰在服务器执行）。

**nginx 收口**：`generate-nginx.py` 跳过带 `baota_site`/`baota_project` 的组件——它们的路由由面板站点 + 原生反代（`CreateProxy`，conf 落 `vhost/nginx/proxy/<site>/`）管理，default.conf 不再生成对应 location，避免双头打架。

## 跨 kind 的铁律（双端都要遵守）

1. **同一 `deploy_path` 禁止给两个组件共用**——python 部署先清空 pkg_dir，后部署者会抹掉先部署者（2026-08-24 deepquant-mcp 覆盖 backend 事故，见 deepquant/project.toml 头注记）。
2. **`.env` 默认全排除**，唯一放行通道是 `include_env` 白名单；真实密码只活在 `deploy.env*`，部署时占位符渲染。
3. **python 清空保留名单**：`.env` `.venv` `logs` `data`——回滚侧（backup-rollback.sh）的 find 排除必须与此一致，否则回滚后服务起不来。
4. **备份内容按 kind 区分**：frontend 只备 dist；python/java/go/nodejs 备 pkg_dir 但**不含 .venv**（backup_frontend / backup_backend 分工）。
5. **健康检查**（`health_check`，3 次尝试）失败返回 1，**双端均闭环**：部署路径（deploy-kinds.sh 4 处）捕获后该组件部署计为失败（批次汇总计入 failed、退出码非零、提示可回滚）；回滚路径（backup-rollback.sh）同理。

## 双端同步核对清单（改 kind 行为后逐项勾）

- [ ] pack.ps1（PowerShell 端）已改并实测打包
- [ ] scripts/kind/deploy-kinds.sh + scripts/deploy-python.sh（Bash 端）已改
- [ ] 两端读取的字段名一致（`scripts/core/config_loader.py` 的 `_KEY_MAP` snake→camel 映射是否需要新增）
- [ ] `tests/run-all.sh` 全绿
- [ ] 真实部署一次验证（dist/lib 会随包同步到服务器，无需手动 scp lib）
