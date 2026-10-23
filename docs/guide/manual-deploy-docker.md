# 手动部署 · Docker 通道（docker，MVP 试点）

> **Category**: Guide
>
> 适用：`DEPLOY_CHANNEL=docker`。**状态：MVP 骨架（2026-10-22），未在真实 docker 主机全链路验证——启用前先单组件试点**（已试点 deepquant-backend 全绿）。
> 定位（用户拍板）：**应用容器统一维护 + 宿主 nginx 收口路由 + PG/Redis 等基础设施宿主化**——宿主 nginx 是正式设计组成，不是技术债。
> 与宝塔**不共存**（registry 强制，同机二选一）。

## 目录

- [设计要点](#设计要点)
- [前置条件](#前置条件)
- [自动化部署](#自动化部署)
- [手动部署 Python 组件](#手动部署-python-组件)
- [手动部署前端](#手动部署前端)
- [运维（状态/日志/回滚）](#运维状态日志回滚)
- [局限与注意](#局限与注意)

---

## 设计要点

TOML 意图 → docker 翻译（`scripts/channels/docker.sh`）：

| TOML 意图 | docker 通道落地 |
|-----------|----------------|
| `process(port, cmd)` | Dockerfile（构建时 pip install，依赖装进镜像）+ `docker compose up -d` |
| `mcp_server/` 附加源码 | 镜像内一并安装（`channel_wants_host_venv=0`，无宿主 venv） |
| `companions` | **预留**（后续每伴随一个 compose service；当前不支持） |
| `routes(proxy/websocket)` | 宿主 nginx 代理 → `127.0.0.1:<process.port>`（路由后端 = native-nginx.sh 共用） |
| `routes(root/static)` | 宿主目录落静态文件（与 native 相同，容器化无收益） |

**关键约束**：
- 容器内应用必须绑 `0.0.0.0`；端口发布绑定 `127.0.0.1`（路由由宿主 nginx 收口，不直接暴露）。
- `network_mode: host`——容器内 `127.0.0.1` 即宿主，PG/Redis 零改动直连。
- `deploy_hook`（legacy）在 docker 通道**跳过**，走默认流程。

## 前置条件

| 项 | 要求 |
|----|------|
| docker 引擎 + compose 插件 | `docker info`、`docker compose version` 可用 |
| 镜像加速（国内必需） | `/etc/docker/daemon.json` 配 `registry-mirrors`（VM 已配 daocloud+腾讯） |
| 容器内 pip 源 | Dockerfile 模板内置 `pip config set` 腾讯源（容器不继承宿主 pip.conf） |
| 宿主 nginx | 与 native 共用 generate-nginx 路由 |
| PG / Redis / Kafka | 跑宿主，容器应用直连（**不在容器内**） |
| env 键 | 无 docker 专属键 |

> 完整安装包清单（含镜像加速配置）→ [install-packages.md](./install-packages.md)；命令速查 → [cheatsheet-commands.md](./cheatsheet-commands.md)。

## 自动化部署

```bash
# deploy.env.server-X 加一行
DEPLOY_CHANNEL=docker

# 打包 + 部署（与宝塔/native 相同入口，通道自动切换）
.\scripts\build.ps1 deepquant
bash deploy.sh deepquant-backend --target=<docker机> --yes
```

脚本自动完成：渲染 Dockerfile + compose（幂等，每次部署重新渲染）→ 构建镜像 →
`compose up -d` → 健康检查（`process.port`）→ 宿主 nginx 路由同步 reload。

## 手动部署 Python 组件

脚本不可用时逐项手动（以 deepquant-backend，端口 5000 为例）：

```bash
PKG_DIR=/www/wwwroot/project/deepquant/backend/package
cd "$PKG_DIR"

# 1. 代码同步（同 native：保留 .env/logs/data，无 .venv 概念）
find . -mindepth 1 -maxdepth 1 ! -name '.env' ! -name 'logs' ! -name 'data' \
    -exec rm -rf {} + 2>/dev/null || true
tar xzf /www/wwwroot/project/uploads/dist/packages/deepquant-backend-*.tar.gz -C .

# 2. 渲染 Dockerfile + compose（正常由 channel_python_install 生成；手写时参考）
#    Dockerfile 要点：
#      FROM python:3.x-slim → pip 换腾讯源 → COPY . /app → WORKDIR /app/package
#      → pip install 依赖（含 mcp_server/ 如有）→ CMD 按 process.cmd（绑 0.0.0.0）
#    compose 要点：
#      network_mode: host；restart: unless-stopped；
#      端口发布 "127.0.0.1:5000:5000"（绑回环）

# 3. 构建 + 启动
docker compose build
docker compose up -d

# 4. 迁移（MVP：迁移在部署时于宿主 venv 执行——docker 通道如无宿主 venv，
#    可进容器执行一次）
docker compose exec app .venv/bin/alembic upgrade head   # 或镜像内等价命令

# 5. 健康检查
curl -sf http://127.0.0.1:5000/api/health | python3 -m json.tool
```

## 手动部署前端

与 native 完全相同（静态文件落宿主目录 + 宿主 nginx 路由），
见 [manual-deploy-native.md § 手动部署前端](./manual-deploy-native.md#手动部署前端)。

## 运维（状态/日志/回滚）

```bash
bash deploy.sh --status     # 通道视图：docker inspect
bash deploy.sh --logs deepquant-backend    # docker logs
# 或直接：
docker compose -f <pkg_dir>/docker-compose.yml ps
docker logs <容器名> --tail 100 -f

# 代码回滚 = 重新部署旧包（镜像幂等重建）；配置回滚 = 恢复 .env 后 compose up -d --build
```

## 局限与注意

1. **companions 未实现**——有伴随服务的组件（如 financial-api 的 crawler/worker/streaming）暂不能上 docker 通道。
2. **java 不支持**——`channel_supported_kinds = frontend python`。
3. **纯容器零 nginx 不支持**——宿主 nginx 是路由层正式组成。
4. **迁移时机**（`process.migrate`）在 docker 通道为预留——当前需手动进容器/宿主执行。
5. 切换通道前先跑 ops 清场脚本恢复初始状态（同机单通道铁律）。
6. 多容器编排、状态视图尚待验证——试点时逐组件推进，勿一次全量迁移。
