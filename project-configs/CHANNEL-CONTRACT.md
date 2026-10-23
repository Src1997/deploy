# CHANNEL-CONTRACT — 三通道统一动词契约 v2（native / baota / docker）

> **用途**：部署 = **kind × channel** 矩阵。
> **kind**（frontend / backend 按语言：python、java）= 组件类型，决定"做什么"
> （找包→备份→解压→.env→依赖→健康门的公共流程，见 `kind/`）；
> **channel**（baota / native / docker）= 运行载体，决定"落在哪、怎么跑"。
> **改任何通道行为前先读本文；新增通道必须完整实现全部动词并通过 L1 动词审计。**
> 配置 SSOT 是 `project-configs/<项目>/project.toml`（★v2 意图模型：
> 只声明 routes / process / companions，无任何通道字眼）；kind 打包契约见
> `KINDS-CONTRACT.md`，TOML 字段详解见 `PROJECT-TOML-GUIDE.md`，
> **各通道依赖包清单（用到哪些包/边界红线）见 `CHANNEL-DEPENDENCIES.md`**。

## 1. 通道选择与所有权（v2 核心原则）

```
DEPLOY_CHANNEL = native | baota | docker     # deploy.env.<target> 或 --channel=
```

- **兼容**：未设置时 `BAOTA_MODE=1` → baota，否则 → native。
- **同机单通道**：一台服务器只落一种通道（用户 2026-10-22 定）。
  registry 强制：docker 与宝塔互斥告警；切换通道前先用 ops 清场脚本恢复初始状态。
- **★所有权彻底**：服务操作（重启/状态/日志/已部署探测）一律走通道动词——
  baota = 面板 API + 宝塔 supervisor，不碰 systemd/宿主 nginx；
  native = systemd + 宿主 nginx（generate-nginx 路由后端 `channel/native/nginx.sh`）；
  docker = docker/compose + 宿主 nginx 路由。

## 2. 通道注册（scripts/channel/registry.sh）

1. 解析 `DEPLOY_CHANNEL`（含 BAOTA_MODE 兼容映射）；
2. source `channel/<channel>/channel.sh` **恰好一个**；
3. **能力断言**：逐个检查 §3 动词，缺失即 fail-fast。

## 3. 通道动词（16 个，每通道必须同名实现）

| 动词 | 签名 | 语义 |
|----|----|----|
| `channel_name` | — | echo 通道名 |
| `channel_supported_kinds` | — | echo 支持的 kind |
| `channel_wants_host_venv` | — | echo 1/0：python 是否需要宿主 venv（docker=0） |
| `channel_routing_sync` | — | 路由全量收口（native/docker=generate-nginx；baota=拒绝，归面板） |
| `channel_frontend_prepare <id>` | 组件 id | 前置+解析目标目录并 **echo**（baota=建站+SSOT+反代）。DRY_RUN 安全 |
| `channel_frontend_preserve <id> <target>` | id+目标 | 清空前保存通道资产（baota=.user.ini） |
| `channel_frontend_restore <id> <target>` | id+目标 | 解压后还原（与 preserve 成对） |
| `channel_frontend_finalize <id> <target>` | id+目标 | 单组件路由收口（native/docker=nginx reload；baota=no-op） |
| `channel_python_install <id> <pkg_dir>` | id+目录 | 服务化安装（native=systemd 模板；docker=渲染 Dockerfile/compose；baota=no-op） |
| `channel_python_restart <id> <pkg_dir>` | id+目录 | 启动/重启（baota=ensure 项目+supervisor；native=SERVICES 逐个；docker=compose up） |
| `channel_java_install <id> <pkg_dir>` | id+目录 | 同上（java 版） |
| `channel_java_restart <id> <pkg_dir>` | id+目录 | 同上（java 版） |
| `channel_service_running <svc>` | 服务名 | exit 0=运行中（baota=supervisor；native=supervisor→systemd；docker=inspect） |
| `channel_service_restart <svc>` | 服务名 | 单服务重启 |
| `channel_status` | — | `--status` 输出（通道自己的视图） |
| `channel_logs <svc> <mode>` | 服务名+mode | `--logs`（mode: follow / N / error） |

## 4. 意图 → 通道翻译表（v2 灵魂）

| TOML 意图 | baota | native | docker |
|----|----|----|----|
| `routes(type=root/static)` | 宝塔 HTML 站点 | generate-nginx location | 宿主 nginx 静态 |
| `routes(type=proxy/websocket)` | 面板原生反代 CreateProxy | generate-nginx proxy | 宿主 nginx 代理 → 容器（host 网络，端口即宿主端口） |
| `process(port,cmd)` | 宝塔 Python/Java 项目（名=组件 id，cmd 自动拼 deploy_path 绝对路径） | systemd 单元 `<id>.service`（模板 assets/systemd/） | Dockerfile + compose（port 发布 127.0.0.1） |
| `process(migrate)` | 部署时 venv 内执行 | 同左 | 镜像构建/启动时（预留） |
| `process(jar,jdk)`（java） | 宝塔 Java 项目 | systemd | 暂不支持 |
| `companions` | 宝塔 supervisor 程序 | systemd 单元 `<name>.service` | 预留 |

## 5. 通道实现现状（2026-10-22）

| 通道 | 目录 | 状态 | 说明 |
|----|----|----|----|
| **baota** | `channel/baota/`（channel.sh + baota_api.py） | ✅ 主力 | 全宝塔所有权：站点/反代/项目/supervisor/状态/日志 |
| **native** | `channel/native/`（channel.sh + nginx.sh） | ✅ 冻结维护 | systemd + generate-nginx；A/B 应急；hybrid supervisor 探测 |
| **docker** | `channel/docker/` | ⚠️ MVP | **定位（用户 2026-10-22 拍板）**：应用容器统一维护 + 宿主 nginx 收口路由 + PG/Redis 等基础设施宿主化——"需要别的包配合没问题"，宿主 nginx 是正式组成而非技术债。已试点 deepquant-backend 全绿；多容器/状态视图待验 |

## 6. env 键

`DEPLOY_CHANNEL`；baota 另需 `BAOTA_PANEL_URL` / `BAOTA_API_KEY`（api.json 的
token 字段，★不是 key）/ `BAOTA_PYTHON` / `BAOTA_SUPERVISORCTL`；
面板 api.json `limit_addr` 必须含 127.0.0.1。

## 7. 新增通道核对清单

- [ ] `scripts/channel/<name>/channel.sh` 实现 §3 全部 16 动词
- [ ] `registry.sh` 通道表登记 + 互斥约束（如有）
- [ ] `config_loader.py` 若需新意图键：entry + bash-eval 两处同步
- [ ] `tests/run-all.sh` 第 9 项自动覆盖动词审计
- [ ] 本文件 §5 更新；真机单组件试点后再标 ✅
