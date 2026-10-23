# CHANNEL-DEPENDENCIES — 三通道依赖清单（每个通道用到哪些包）

> **用途**：回答"每个通道用到哪些包/组件、边界在哪"。部署 = kind × channel，
> 通道间互斥（同机单通道），本文按通道列出**本地构建侧**与**服务器运行侧**
> 的全部依赖，以及各通道**刻意不碰**的东西（干净度边界）。
> 动词契约见 `CHANNEL-CONTRACT.md`，配置字段见 `PROJECT-TOML-GUIDE.md`。

## 0. 全通道公共依赖

| 侧 | 依赖 | 说明 |
|---|---|---|
| 本地（Windows 构建） | Python 3.13（受管） | config_loader.py / 打包（唯一解释器 SSOT） |
| 本地 | tar / ssh | 前端包打包 + 上传（tar 管道，scp 不可用） |
| 本地 | pnpm（前端 kind） | 由 TOML build.package_manager 决定（pnpm/npm/yarn） |
| 服务器 | bash 3.2+ / curl / python3 | deploy.sh 运行时；python3 供派生 JSON 消费 |

## 1. 宝塔通道（baota）——"面板统一维护"

| 侧 | 依赖 | 版本/路径 | 用途 |
|---|---|---|---|
| 服务器 | **宝塔面板** | 入口 :27895（VM 实证） | 站点/反代/Python·Java 项目的 SSOT |
| 服务器 | **宝塔 supervisor 插件** | `/www/server/panel/pyenv/bin/supervisorctl` | 伴随服务守护（companions） |
| 服务器 | 面板自带 Python | `BAOTA_PYTHON`（pyenv/bin/python3） | baota-api.py 运行（纯标准库） |
| 服务器 | ss（iproute2） | 系统自带 | 重启后端口就绪轮询 |
| 服务器 | 项目 venv | deploy_path/.venv | python kind 宿主 venv（pip 装依赖） |
| 面板配置 | api.json：token + limit_addr 含 127.0.0.1 | 面板设置→API接口 | HTTP 签名调用 |
| env 键 | `BAOTA_PANEL_URL` `BAOTA_API_KEY` `BAOTA_PYTHON` `BAOTA_SUPERVISORCTL` | deploy.env.* | 通道凭证与路径 |

**不碰**：systemd 单元、宿主 nginx conf（default.conf）、`--sync-nginx`（直接返回，路由归面板）。

## 2. 原生通道（native）——"systemd + 宿主 nginx"

| 侧 | 依赖 | 版本/路径 | 用途 |
|---|---|---|---|
| 服务器 | **systemd** | 任何现代发行版 | 主进程 + companions 守护（单元模板 assets/systemd/） |
| 服务器 | **nginx** | 宿主任意安装方式 | 路由收口（generate-nginx 生成 default.conf） |
| 服务器 | nginx -t / reload 权限 | root | 配置测试与重载 |
| 服务器 | python3-venv | venv 模块 | python kind 宿主 venv |
| 服务器 | supervisorctl（可选） | 有则探测（hybrid） | 旧机 supervisor 残留服务的 status/logs 识别 |
| env 键 | `MCP_AGENT_TOKEN`（deepquant 专用） | deploy.env.* | systemd 单元模板渲染 |

**不碰**：宝塔面板 API、宝塔 supervisor 注册表、面板站点/反代。

## 3. docker 通道（docker）——"容器统一维护"（MVP→转正中）

| 侧 | 依赖 | 版本/路径 | 用途 |
|---|---|---|---|
| 服务器 | **docker 引擎 + compose 插件** | VM 实证 29.1.3 | 镜像构建 + 容器编排 |
| 服务器 | **镜像加速**（国内必需） | `/etc/docker/daemon.json` registry-mirrors（VM 已配 daocloud+腾讯） | 拉基础镜像 |
| 服务器 | 容器内 pip 腾讯源 | Dockerfile 模板内置 `pip config set` | 依赖安装（容器不继承宿主 pip.conf） |
| 服务器 | **宿主 nginx**（与 native 共用路由后端） | generate-nginx | 前端静态 + 反代到容器端口（★正式组成，非技术债——用户 2026-10-22 拍板） |
| 服务器 | host 网络 | compose `network_mode: host` | 容器内 127.0.0.1 = 宿主（PG/Redis 零改动） |
| 基础设施 | PG / Redis / Kafka 跑宿主 | — | 容器应用直连（不在容器内） |
| env 键 | 无专属键 | — | 纯 docker CLI |

**不碰**：面板 API、systemd 单元、supervisor。**局限**：python 支持（java 未实现）；纯容器零 nginx 不支持（宿主 nginx 是路由层正式组成）。

## 4. 依赖矩阵速查（谁碰什么）

| 组件 | 宝塔 | 原生 | docker |
|---|---|---|---|
| 主进程守护 | 面板 Python/Java 项目 | systemd 单元 | 容器 |
| 伴随服务 | supervisor 程序 | systemd 单元 | companion 容器（需对象形式 cmd） |
| 前端落点 | 宝塔站点（root=deploy_path） | deploy_path | deploy_path（宿主目录） |
| 路由 | 面板反代 | generate-nginx | generate-nginx |
| 进程探测 | supervisorctl + 面板项目 | systemctl（supervisor 兜底） | docker inspect |
| 日志 | supervisorctl tail | journalctl / supervisor | docker logs |
| 迁移执行 | 部署时 venv 内 | 部署时 venv 内 | （预留：镜像构建/启动时） |
| legacy deploy_hook | ✅ 支持 | ✅ 支持 | ❌ 跳过（走默认流程） |

## 5. 清净度红线（通道间互不越权）

1. **同机单通道**：一台服务器只落一种通道；切换前先跑 ops 清场脚本恢复初始状态。
2. baota 通道代码里禁止出现 `systemctl` / `nginx -t`；native 禁止出现面板 API 调用；docker 禁止出现两者。
3. 跨通道共享资产只允许三类：路由后端 `native-nginx.sh`（native/docker 共用）、systemd 单元模板（仅 native）、.env 模板（全通道）。
4. L1 第 9 项动词审计 + 本文件任何修改需同步 CHANNEL-CONTRACT.md。
