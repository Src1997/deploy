#!/usr/bin/env bash
# ============================================================================
# Financial API — 跨平台打包脚本（薄封装 → 通用打包逻辑）
#
# 实际打包配置来自 projects.json，此脚本保留旧命令入口。
#
# Usage:
#   bash deploy/scripts/pack-financial-api.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 加载项目清单
# shellcheck source=lib/load-projects.sh
source "$SCRIPT_DIR/lib/load-projects.sh" 2>/dev/null || {
    echo "[ERR] Failed to load projects.json"
    exit 1
}

# 从 projects.json 读取 financial-api 配置
PROJ_ID="financial-api"
SOURCE_PATH="${WORKSPACE_ROOT:-$(dirname "$DEPLOY_DIR")}"

# 查找 sourcePath
if command -v jq &>/dev/null; then
    SRC_REL=$(jq -r '.projects[] | select(.id=="'"$PROJ_ID"'") | .sourcePath' "$PROJECTS_FILE")
    ARTIFACT=$(jq -r '.projects[] | select(.id=="'"$PROJ_ID"'") | .build.artifactPattern // .build.artifact' "$PROJECTS_FILE")
else
    SRC_REL=$(python3 -c "import json; d=json.load(open('$PROJECTS_FILE')); [print(p['sourcePath']) for p in d['projects'] if p['id']=='$PROJ_ID']" 2>/dev/null)
    ARTIFACT=$(python3 -c "import json; d=json.load(open('$PROJECTS_FILE')); [print(p.get('build',{}).get('artifactPattern',p.get('build',{}).get('artifact',''))) for p in d['projects'] if p['id']=='$PROJ_ID']" 2>/dev/null)
fi

SOURCE_DIR="${SOURCE_PATH}/${SRC_REL}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUT_DIR="${DEPLOY_DIR}/dist/packages"
TAR_NAME="${ARTIFACT%%-\*}-${TIMESTAMP}.tar.gz"
TAR_PATH="${OUT_DIR}/${TAR_NAME}"

echo "[*] Packing: $PROJ_ID"
echo "    Source:  $SOURCE_DIR"
echo "    Output:  $TAR_PATH"

mkdir -p "$OUT_DIR"
cd "$SOURCE_DIR"
tar -czf "$TAR_PATH" \
    --exclude=.env --exclude=.venv --exclude=venv \
    --exclude=logs --exclude=__pycache__ --exclude=*.pyc \
    --exclude=.git --exclude=node_modules \
    .

# 附带部署资产
INCLUDE_FILES=(
    "scripts/deploy-financial-api.sh"
    "configs/systemd/financial-api.service"
    "configs/systemd/financial-crawler.service"
    "configs/systemd/financial-worker.service"
    "configs/systemd/financial-streaming.service"
    "configs/financial-api.env.example"
)

echo "    [include] deploy assets..."
for f in "${INCLUDE_FILES[@]}"; do
    src="${DEPLOY_DIR}/${f}"
    if [ -f "$src" ]; then
        tar -rf "$TAR_PATH" -C "$DEPLOY_DIR" "$f" 2>/dev/null || true
    fi
done

echo ""
echo "[OK] Packed: $TAR_NAME"
echo "     Size:  $(du -h "$TAR_PATH" | cut -f1)"
