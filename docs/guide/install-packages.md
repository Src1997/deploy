# 所需安装包清单（按机器 × 按通道）

> **Category**: Guide
>
> 回答"一台机器要跑这套部署体系，到底要装什么"。按**本地构建侧**与**服务器运行侧**
> 分列，服务器侧再按通道区分。依赖边界的技术细节见
> [project-configs/CHANNEL-DEPENDENCIES.md](../../project-configs/CHANNEL-DEPENDENCIES.md)；
> 从零装机的完整顺序见 [deploy-from-scratch.md](./deploy-from-scratch.md)。

## 1. 本地构建侧（Windows，一次性）

| 包 / 工具 | 用途 | 说明 |
|-----------|------|------|
| **Python 3.13（受管）** | config_loader.py / 打包 | 唯一解释器 SSOT，别用系统 Python |
| **Git Bash**（tar / ssh） | 上传管道、跑 L1 测试 | `ssh serverB "cat > 目标" < 本地包` |
| **PowerShell** | build.ps1 打包入口 | 系统自带 |
| **pnpm** | 前端 kind 构建 | 由 TOML `build.package_manager` 决定（pnpm/npm/yarn） |
| Node.js（受管 22.x） | pnpm 底层 | 前端产物本地构建，**服务器不需要 Node** |

## 2. 服务器公共（所有通道）

| 包 / 工具 | 用途 |
|-----------|------|
| bash 3.2+ / curl / python3 | deploy.sh 运行时；python3 供派生 JSON 消费 |
| **PostgreSQL** | 业务库（quant_zc / quantdinger；宝塔软件商店或系统包） |
| **Redis** | 缓存 / 队列（★宝塔机生效配置在 `/www/server/redis/redis.conf`，`/etc/redis/` 是残留） |
| ss（iproute2） | 端口就绪轮询 / 自检，系统自带 |

## 3. 宝塔通道（baota，B/C 现役）

| 包 / 组件 | 来源 | 用途 |
|-----------|------|------|
| **宝塔面板** | 官方安装脚本 | 站点 / 反代 / Python·Java 项目的 SSOT |
| **Nginx** | 宝塔软件商店 | 静态托管 + 反代落点 |
| **supervisor 插件** | 宝塔软件商店 | 伴随服务（companions）守护 |
| **Python 项目管理器** | 宝塔软件商店 | Python 项目注册 / 启停（venv 注册走面板 pyenv） |
| **Java 项目管理器** | 宝塔软件商店（有 java 组件才需要） | Java 项目托管 |
| **acme.sh** | 独立安装 | SSL 证书自动续签（★勿在面板点续签，见 DEPLOY-NOTES） |
| 面板 API 配置（非安装） | 面板设置 → API 接口 | `api.json` 的 **token 字段** + `limit_addr` 必须含 127.0.0.1 |

**不装 / 不碰**：systemd 业务单元（禁双轨）、Node.js（前端本地构建）。

## 4. native 通道（冻结维护，应急机）

| 包 / 工具 | 用途 |
|-----------|------|
| **systemd** | 主进程 + companions 守护（发行版自带） |
| **nginx** | 路由收口（generate-nginx 生成 default.conf）；`nginx -t`/reload 需 root |
| **python3-venv** | 宿主 venv（deploy_path/.venv） |
| supervisorctl（可选） | hybrid 探测旧机残留服务（有则识别，无则跳过） |

**不碰**：宝塔面板 API、面板 supervisor 注册表、面板站点/反代。

## 5. docker 通道（MVP 试点）

| 包 / 组件 | 用途 |
|-----------|------|
| **docker 引擎 + compose 插件** | 镜像构建 + 编排（`docker info` / `docker compose version` 验证） |
| **镜像加速配置**（国内必需） | `/etc/docker/daemon.json` 配 `registry-mirrors`（VM 实证 daocloud+腾讯） |
| **宿主 nginx** | 路由收口（与 native 共用 generate-nginx 后端；★正式设计组成） |
| 容器内 pip 腾讯源 | Dockerfile 模板内置 `pip config set`（容器不继承宿主 pip.conf） |

**架构约定**：PG / Redis / Kafka 跑宿主，容器应用直连（不在容器内）；无 docker 专属 env 键。

## 6. 业务依赖（随部署自动装，无需预装）

| 依赖 | 安装位置 | 说明 |
|------|----------|------|
| Python 依赖（requirements.txt / pyproject.toml） | 服务器 deploy_path/.venv（baota/native）；容器镜像内（docker） | 部署时 pip 安装 |
| MCP 附加源码（`mcp_server/`） | 同上共享 venv | 部署时自动检测安装；★`mcp` 包 **pin `<2.0.0`**，升级即断 |
| 前端依赖 | **本地构建时** pnpm 安装 | 服务器只收 dist 静态产物 |

## 7. env 键速查（配置而非安装，但常一起查）

| 键 | 通道 | 说明 |
|----|------|------|
| `DEPLOY_CHANNEL` | 全部 | baota / native / docker（兼容旧 `BAOTA_MODE=1`） |
| `BAOTA_PANEL_URL` / `BAOTA_API_KEY` | baota | 面板地址（本机 https://127.0.0.1:端口）/ api.json 的 token |
| `BAOTA_PYTHON` / `BAOTA_SUPERVISORCTL` | baota | 面板 pyenv python3 / supervisorctl 路径 |
| `PG_PASSWORD` / `REDIS_PASSWORD` | 全部 | 业务密码，.env 占位符渲染源 |
| `MCP_AGENT_TOKEN` | native（deepquant） | systemd 单元模板渲染 |
| `BASE_DOMAIN` | 自检 | check-deploy.sh 入参（非 env 文件） |

完整模板见 [deploy.env.example](../../deploy.env.example)。
