# WSL 本地测试

不碰生产机。在 Ubuntu WSL 里验证打包、沙箱部署与回滚。

## 一键补依赖

```bash
wsl -d Ubuntu
cd /mnt/d/Workspace/deploy
python3 tests/wsl-bootstrap.py
```

会：统一 `.sh` 为 LF、`apt` 安装基础工具、确认 nvm/node/pnpm、输出探针结果。

## 冒烟 + 沙箱（含回滚）

```bash
cd /mnt/d/Workspace/deploy
chmod +x tests/*.sh scripts/*.sh

bash tests/wsl-smoke.sh
bash tests/wsl-smoke.sh --pack

# 含：单项目 / 多项目 / 真实 deploy.sh 回滚（需输入逻辑已用 --yes）
bash tests/wsl-sandbox.sh demo
bash tests/wsl-sandbox.sh clean
```

### 回滚命令（沙箱）

```bash
bash tests/wsl-sandbox.sh init && bash tests/wsl-sandbox.sh seed-packages
bash tests/wsl-sandbox.sh deploy-static financial-web
bash tests/wsl-sandbox.sh deploy-static official-site

# 单项目（会提示输入 yes）
bash tests/wsl-sandbox.sh rollback financial-web

# 多项目
bash tests/wsl-sandbox.sh rollback financial-web,official-site --yes

# 全部静态站
bash tests/wsl-sandbox.sh rollback all --yes

# 走真实 scripts/deploy.sh
bash tests/wsl-sandbox.sh rollback-via-deploy 'financial-web,official-site' --yes
```

### 服务器侧（deploy.sh）回滚摘要

| 场景 | 命令 |
|------|------|
| 单项目 | `bash deploy.sh financial-web --rollback` |
| 多项目最新 | `bash deploy.sh financial-web,official-site --rollback=latest` |
| 全量 | `bash deploy.sh all --rollback` |
| 跳过确认 | 同上加 `--yes`（慎用） |

确认时必须输入 **`yes`**。正式回滚说明见仓库根 [README.md 回滚](../README.md#回滚)。

沙箱目录：`$HOME/deploy-sandbox`（`DEPLOY_SANDBOX` 可覆盖）。
