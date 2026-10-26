# 通道切换与清场手册

> **Category**: Guide
>
> 同机单通道铁律（CHANNEL-CONTRACT §5）：一台服务器只落一种通道，
> docker 与宝塔互斥（registry 强制告警）。**切换通道前必须清场**，
> 把机器恢复到「初始状态」，再按新通道从零部署。

## 1. 切换方向与脚本

| 方向 | 清场脚本 | 说明 |
|------|----------|------|
| baota → docker / 纯净重装 | `scripts/ops/08-cleanup-baota.sh` | 清面板项目/站点/supervisor/vhost 残留/部署产物/systemd 双轨 |
| docker → baota | `scripts/ops/01-cleanup-server.sh` | Docker 侧清理（对位脚本） |
| native → baota | 手动清 systemd 单元 + vhost（B/C 已于 2026-10-23 完成收编，见审计报告 §一） | 无专用脚本 |
| baota → native | `08-cleanup-baota.sh` 后按 [manual-deploy-native.md](./manual-deploy-native.md) 装机 | 仅应急机 |

## 2. 08-cleanup-baota.sh 用法（服务器上执行）

```bash
bash scripts/ops/08-cleanup-baota.sh --check      # ① 先只探测，列出将清理的项（不动任何东西）
bash scripts/ops/08-cleanup-baota.sh --keep-venv  # ② 清场但保留 Python 项目 venv
                                                  #    （重装同版本时省 pip 重装，如 deepquant package/.venv）
bash scripts/ops/08-cleanup-baota.sh --yes        # ③ 全量清场（跳过逐项确认）
```

清理范围：A 面板记录（Python 项目 + 全部站点，含 Java）→ B nginx vhost 残留
（站点 conf + proxy/extension/rewrite/ssl 子目录 + reload）→ C supervisor 程序
（stop + 删 ini + reread/update）→ D Python 项目文件系统痕迹（venv 注册表等）→
E 部署产物（uploads / backup / 部署包目录）→ F systemd 双轨残留。

**保留**：`$PROJECT_BASE/deploy.env`（重部署需要；丢了也能随 dist 重传再生）。

## 3. 标准切换流程（6 步）

```bash
# ① 探测：确认将清理哪些对象，无意外
bash scripts/ops/08-cleanup-baota.sh --check

# ② 备份：业务数据 + 关键配置（清场不碰 DB，但稳妥起见）
PGPASSWORD="$PG_PASSWORD" pg_dump -U root -h localhost quant_zc | gzip > /root/pre-switch-$(date +%Y%m%d).sql.gz
cp -r /www/wwwroot/project/deploy.env* /root/

# ③ 清场（按需 --keep-venv）
bash scripts/ops/08-cleanup-baota.sh --yes

# ④ 改通道：deploy.env.server-X 里
#    DEPLOY_CHANNEL=docker   （或 baota / native；删掉则回落 BAOTA_MODE 兼容逻辑）

# ⑤ 单组件试点（勿一次全量；docker 通道尤其如此）
bash deploy.sh <一个组件> --target=server-X --yes

# ⑥ 全量部署 + 自检
bash deploy.sh <项目组> --target=server-X --yes
BASE_DOMAIN=<生产域名> bash scripts/tools/check-deploy.sh
```

## 4. 切换后遗留物检查清单（防「半切换」）

```bash
# systemd 双轨（宝塔机必查——残留单元会抢端口，Restart=always 反抢实证）
systemctl list-units --type=service | grep -E 'financial|quantdinger|deepquant'

# cron 残留（@reboot 拉起旧服务）
crontab -l | grep -vE '^#'

# supervisor 孤儿程序
/www/server/panel/pyenv/bin/supervisorctl status

# nginx vhost 孤儿 conf（指向已清空目录）
ls /www/server/panel/vhost/nginx/
nginx -T 2>/dev/null | grep -E "root|proxy_pass" | sort -u

# 监听端口归属（应只剩面板/nginx/DB/新通道进程）
ss -tlnp | grep -E '5000|5001|7800|6379|5432'
```

发现残留 → 回到 §2 对应清理范围补清，再重跑自检。

## 5. 红线

1. 清场脚本会**删站点与项目记录**——生产数据（DB / 上传文件 / .env）先备份再动手。
2. 清场 ≠ 卸载宝塔插件——supervisor / Python 项目管理器保留，重部署直接复用。
3. 切到 docker 前确认目标机满足依赖（镜像加速、宿主 nginx）——见 [install-packages.md](./install-packages.md) §5。
4. B/C（生产）**不切换**：现役 baota，docker 仅试点机。
