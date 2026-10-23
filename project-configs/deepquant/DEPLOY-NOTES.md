# deepquant 部署备注 — 特殊配置与调整指南（2026-10-23 定稿）

> 部署形态：宝塔全托管（B=deepquant.club 主、C=镜像同构部署）。
> 符合性自检：`BASE_DOMAIN=www.deepquant.club bash scripts/tools/check-deploy.sh`。

## 1. deepquant-backend（Flask/gunicorn :5000）

| 项 | 说明 |
|---|---|
| 托管 | 宝塔 Python 项目（面板 → 网站 → Python，可启停/看日志） |
| 绑定 | **127.0.0.1:5000**（仅本机 nginx 反代；2026-10-23 加固） |
| 绑定配置 | 部署副本 `/www/wwwroot/project/deepquant/backend/package/gunicorn_config.py`；**源码 SSOT**：`deepquant/backend_api_python/gunicorn_config.py`（`PYTHON_API_HOST` 默认 127.0.0.1，可用同名环境变量覆盖端口/绑定） |
| 重启 | 面板项目页重启，或服务器上 `... baota-api.py restart-python deepquant-backend`（姿势见 financial/DEPLOY-NOTES.md §2） |
| ⚠️ | 改绑定/端口：先改**源码**再同步部署副本（只改部署副本，下次部署会被覆盖回源码行为） |

## 2. quantdinger-mcp（FastMCP :7800）

| 项 | 说明 |
|---|---|
| 托管 | 宝塔 supervisor（`/www/server/panel/plugin/supervisor/profile/quantdinger-mcp.ini`） |
| 传输 | **streamable-http**（ini 内 `QUANTDINGER_MCP_TRANSPORT=streamable-http`）——mcp 1.30.0 的 SSE 传输有 bug（session POST 挂起），勿改回 sse |
| 端口 | `QUANTDINGER_MCP_HOST=127.0.0.1` / `PORT=7800`；后端桥接 `QUANTDINGER_BASE_URL=http://127.0.0.1:5000` |
| Agent Token | ini 内 `QUANTDINGER_AGENT_TOKEN`（B/C 各自独立值） |
| ⚠️改 ini 后 | `supervisorctl reread && supervisorctl update && supervisorctl restart quantdinger-mcp`（restart 单独执行不重读 ini） |

### 对外入口（两台的 financial-web conf 内 `/mcp` 块）

```
location /mcp {
    proxy_pass http://127.0.0.1:7800;
    proxy_set_header Host 127.0.0.1:7800;   # ★必须：FastMCP 拒绝非回环 Host（421）
    proxy_buffering off;                     # ★必须：streamable-http 流式响应
    ...标准 proxy 头
}
```
- 客户端调用必须带 `Accept: application/json, text/event-stream`（缺了 406）。
- 健康探测：`curl -X POST https://<域名>/mcp -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","method":"initialize",...}'` → 200。

## 3. 依赖红线

- `mcp` 库 **pin `<2.0.0`**（`mcp_server/pyproject.toml`）：mcp 2.x 把 FastMCP 改名 MCPServer，直接崩。新依赖必须带上限（工具箱 L1 测试有审计项）。

## 4. 前端（/quant/ 子路径）

- vite `base=/quant/`，部署到 `/www/wwwroot/project/deepquant/web/dist`；线上由 financial-web.local 站点的 `/quant/` location（alias + try_files + ws 反代 5000）承载——**路由在 financial 的 conf 里调**，见 financial/DEPLOY-NOTES.md §1。
- deepquant-web.local 独立站点（html_deepquant-web.local.conf）作为 alias 源的注册壳。

## 5. mt5-bridge

- 只写主 B（C 不进 MT5 库）；C 端行情/MT5 走 B 的 Redis（WireGuard 10.10.0.2）。
