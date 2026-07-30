#!/usr/bin/env bash
# ============================================================================
# Financial API — 跨平台打包脚本（pack.ps1 的 Linux/macOS/WSL 等价实现）
#
# 将后端源码 + deploy.sh + systemd 服务文件打包为 tar.gz，输出到 deploy/dist/。
# 产物结构与 pack.ps1 完全一致，服务器端 deploy.sh 可直接识别。
#
# Usage:
#   bash deploy/scripts/pack-financial-api.sh
# ============================================================================
set -euo pipefail

# ── 路径定位 ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"          # deploy/scripts/
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"              # deploy/
WORKSPACE_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"          # workspace root
API_SRC="$WORKSPACE_DIR/financial/financial-api"        # financial-api 源码
CONFIGS_DIR="$DEPLOY_DIR/configs"                      # 配置文件
OUTPUT_DIR="$DEPLOY_DIR/dist"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# ── 输出辅助 ──────────────────────────────────────────────────────────────────
log()  { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }

# ── 校验后端目录 ──────────────────────────────────────────────────────────────
if [[ ! -d "$API_SRC/app" ]]; then
    printf '\033[31m[ERR]\033[0m Backend directory not found: %s\n' "$API_SRC" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

printf '\n\033[36m========================================\033[0m\n'
printf '\033[36m  Financial API — Pack Tool (bash)\033[0m\n'
printf '\033[36m========================================\033[0m\n\n'

# ── 准备临时 staging 目录 ─────────────────────────────────────────────────────
# 用固定子目录名 package/，保证 tar 解压后路径一致，deploy.sh 据此定位代码
STAGING_ROOT="$(mktemp -d)"
STAGING="$STAGING_ROOT/package"
mkdir -p "$STAGING"

log 'Packing backend (financial-api)'

# ── 生成 VERSION 文件（git commit + 打包时间）──────────────────────────
GIT_HASH="unknown"
GIT_BRANCH="unknown"
GIT_DIRTY=""
if command -v git >/dev/null 2>&1; then
    GIT_HASH=$(git -C "$API_SRC" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    GIT_BRANCH=$(git -C "$API_SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    if [ -n "$(git -C "$API_SRC" status --porcelain 2>/dev/null)" ]; then
        GIT_DIRTY=" (dirty: uncommitted changes)"
    fi
fi
cat > "$STAGING/VERSION" <<EOF
project: financial-api
commit: $GIT_HASH
branch: $GIT_BRANCH$GIT_DIRTY
packed_at: $(date '+%Y-%m-%d %H:%M:%S')
packed_by: $(whoami)@$(hostname)
EOF
printf '  \033[90mAdded: VERSION (%s%s)\033[0m\n' "$GIT_HASH" "$GIT_DIRTY"

# ── 复制代码目录与配置文件 ────────────────────────────────────────────────────
INCLUDE_ITEMS=(app worker alembic scripts pyproject.toml alembic.ini .env.example)
for item in "${INCLUDE_ITEMS[@]}"; do
    src="$API_SRC/$item"
    if [[ -e "$src" ]]; then
        cp -a "$src" "$STAGING/"
    else
        warn "Skipped (not found): $item"
    fi
done

# ── 附带 deploy.sh 与 systemd 服务文件 ───────────────────────────────────────
if [[ -f "$SCRIPT_DIR/deploy-financial-api.sh" ]]; then
    cp -a "$SCRIPT_DIR/deploy-financial-api.sh" "$STAGING/"
    printf '  \033[90mAdded: deploy-financial-api.sh\033[0m\n'
fi
if [[ -d "$CONFIGS_DIR/systemd" ]]; then
    cp -a "$CONFIGS_DIR/systemd" "$STAGING/"
    printf '  \033[90mAdded: systemd/\033[0m\n'
fi

# ── 清理 Python 运行时缓存与构建产物 ─────────────────────────────────────────
find "$STAGING" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
find "$STAGING" -type f -name '*.pyc' -delete 2>/dev/null || true
find "$STAGING" -type d -name '*.egg-info' -exec rm -rf {} + 2>/dev/null || true

# ── 压缩 ──────────────────────────────────────────────────────────────────────
log 'Compressing...'
TARBALL="$OUTPUT_DIR/financial-api-$TIMESTAMP.tar.gz"
tar -czf "$TARBALL" -C "$STAGING_ROOT" package

# 清理临时目录
rm -rf "$STAGING_ROOT"

SIZE="$(du -h "$TARBALL" | cut -f1)"
ok "Backend packed: $TARBALL ($SIZE)"

# ── 产物概览 ──────────────────────────────────────────────────────────────────
printf '\n  \033[90mArchive contents (top 25 entries):\033[0m\n'
tar -tzf "$TARBALL" | head -25
printf '\n  \033[90mTotal entries: %s\033[0m\n' "$(tar -tzf "$TARBALL" | wc -l)"

# ── 完成提示 ──────────────────────────────────────────────────────────────────
printf '\n\033[36m[*]\033[0m Done\n'
printf '  \033[32m%s\033[0m\n' "$TARBALL"
printf '\n  \033[90mUpload to server:\033[0m\n'
printf '  \033[90mscp deploy/dist/financial-api-*.tar.gz root@SERVER_IP:/www/wwwroot/project/financial/financial-api/\033[0m\n'
printf '\n  \033[90mDeploy on server:\033[0m\n'
printf '  \033[90mcd /www/wwwroot/project/financial/financial-api && tar xzf financial-api-*.tar.gz && bash package/deploy.sh\033[0m\n\n'
