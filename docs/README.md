# deploy/docs 索引

> **Category**: Guide（导航）

## 操作指南 (guide/)

| 文档 | 说明 |
|------|------|
| [guide/deploy-from-scratch.md](./guide/deploy-from-scratch.md) | 完整部署步骤（Phase 1-8b，从零开始） |
| [guide/incremental-release.md](./guide/incremental-release.md) | 增量发版与回滚（含 deploy_hook 钩子说明） |
| [guide/manual-deploy.md](./guide/manual-deploy.md) | 手动部署总入口（脚本不可用 / 故障排查 / 单步操作；★开头有 2026-10-23 通道现状说明） |
| [guide/manual-deploy-baota.md](./guide/manual-deploy-baota.md) | 手动部署 · 宝塔通道（主力，B/C 现役；面板对象落位 / API 姿势 / 红线） |
| [guide/manual-deploy-native.md](./guide/manual-deploy-native.md) | 手动部署 · native 通道（冻结维护，systemd + generate-nginx 应急） |
| [guide/manual-deploy-docker.md](./guide/manual-deploy-docker.md) | 手动部署 · docker 通道（MVP 试点；容器 + 宿主 nginx 收口） |
| [deploy-architecture.html](./deploy-architecture.html) | 部署体系架构总览（HTML 可视化：端到端流程图 / kind×channel 矩阵 / 思维导图 / 宝塔对象落位） |
| [guide/daily-ops.md](./guide/daily-ops.md) | 日常运维（服务管理、日志治理、故障排查 SOP、数据库、Redis、备份） |
| [guide/remote-dev.md](./guide/remote-dev.md) | 远程开发（直连服务器 DB / 后端） |

## 快速入口

| 场景 | 入口 |
|------|------|
| 磁盘满 / 后端挂 / PG recovery | [daily-ops.md § 常见故障排查 SOP](./guide/daily-ops.md#常见故障排查-sop) |
| 日志治理与磁盘清理 | [daily-ops.md § 日志治理与磁盘清理](./guide/daily-ops.md#日志治理与磁盘清理) |
| 新增 Python / FastAPI 后端 | [README.md § 新增 Python 后端](../README.md#新增-python--fastapi-后端) |
| 钩子泛化测试 | `bash tests/test-hook-generalization.sh`（WSL） |

## 排障档案

| 文档 | 说明 |
|------|------|
| [deploy-troubleshooting-history.md](./deploy-troubleshooting-history.md) | 正式服务器历史排障（原 README 附录） |
| [deploy-audit-20261023.md](./deploy-audit-20261023.md) | B/C 宝塔收编全面审计（非原生配置清单/问题清单/工具箱修改/终验 40 项） |
| [../project-configs/financial/DEPLOY-NOTES.md](../project-configs/financial/DEPLOY-NOTES.md) | financial 特殊配置与调整指南（deepquant / official-site 同目录各有份） |
| [wsl-local-deploy-issues.md](./wsl-local-deploy-issues.md) | WSL 本地宝塔部署问题与最终状态 |
| [baota-linux-panel.openapi.yaml](./baota-linux-panel.openapi.yaml) | 宝塔 Linux 面板 API（Apifox 可导入） |

主入口仍是仓库根目录 [README.md](../README.md)。
