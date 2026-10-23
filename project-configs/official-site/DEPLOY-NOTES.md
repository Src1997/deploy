# official-site（qd 渠道落地页）部署备注（2026-10-23）

## 定位（用户 2026-10-22 明确）

official-site **不是空壳**，是 qd（渠道/引流）项目——"DeepQuant IQ 官方营销落地页"。源码：本地 `D:\Workspace\official-site`。

## 部署形态（B/C 相同）

| 层 | 位置 |
|---|---|
| 产物目录 | `/www/wwwroot/project/official-site/dist`（宝塔站点 official-site.local 的根目录） |
| 独立站点 conf | `/www/server/panel/vhost/nginx/html_official-site.local.conf`（注册壳，无生产域名绑定） |
| 线上入口 | **由 financial-web.local 站点承载**：`https://生产域名/qd/` → conf 内 `location /qd/ { alias /www/wwwroot/project/official-site/dist; ... }` |

★要点：qd 的线上路由**不在本项目的 conf 里调**——在 financial 的站点 conf（`html_financial-web.local.conf` 的 `/qd/` 块）调整，含无斜杠 301（`location = /qd`）。详见 `../financial/DEPLOY-NOTES.md` §1。

## vite 注意

- base=`/qd/`；构建产物 assets 在 dist 顶层，靠 conf 内 alias + try_files 承接，**勿**改回根 base。
