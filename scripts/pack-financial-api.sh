#!/usr/bin/env bash
# ============================================================================
# Financial API — 跨平台打包脚本（薄封装，布局与 pack-generic.ps1 对齐）
#
# 产出: dist/packages/financial-api-<ts>.tar.gz
# 布局（保持层次，禁止拍扁）:
#   package/                 # 应用源码 + VERSION
#   scripts/deploy-financial-api.sh
#   configs/systemd/*.service
#   configs/financial-api.env.example
#
# Usage:
#   bash deploy/scripts/pack-financial-api.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/load-projects.sh
source "$SCRIPT_DIR/lib/load-projects.sh"

PROJ_ID="financial-api"
SRC_REL="$(_json_project_field "$PROJECTS_FILE" "$PROJ_ID" sourcePath)"
SOURCE_DIR="${WORKSPACE_ROOT}/${SRC_REL}"

if [ ! -d "$SOURCE_DIR" ]; then
    echo "[ERR] Source not found: $SOURCE_DIR" >&2
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUT_DIR="${DEPLOY_DIR}/dist/packages"
TAR_NAME="financial-api-${TIMESTAMP}.tar.gz"
TAR_PATH="${OUT_DIR}/${TAR_NAME}"
STAGING=$(mktemp -d)
PKG="${STAGING}/package"

echo "[*] Packing: $PROJ_ID"
echo "    Source:  $SOURCE_DIR"
echo "    Layout:  package/ + scripts/ + configs/"
echo "    Output:  $TAR_PATH"

mkdir -p "$OUT_DIR" "$PKG"

# 源码 → package/
tar -C "$SOURCE_DIR" \
    --exclude=.env --exclude=.venv --exclude=venv \
    --exclude=logs --exclude=__pycache__ --exclude='*.pyc' \
    --exclude=.git --exclude=node_modules \
    -cf - . | tar -C "$PKG" -xf -

# VERSION
{
    echo "project=$PROJ_ID"
    echo "built=$TIMESTAMP"
    echo "host=$(hostname 2>/dev/null || echo unknown)"
} > "$PKG/VERSION"
echo "    [ok]      package/VERSION"

# include：相对 deploy 根路径原样保留（禁止 basename）
_list_includes() {
    if command -v jq &>/dev/null; then
        jq -r ".projects[] | select(.id==\"$PROJ_ID\") | .build.include[]?" "$PROJECTS_FILE"
    else
        python3 -c "
import json
d=json.load(open('$PROJECTS_FILE'))
for p in d.get('projects',[]):
    if p.get('id')=='$PROJ_ID':
        for x in (p.get('build') or {}).get('include') or []:
            print(x)
"
    fi
}

while IFS= read -r f; do
    [ -z "$f" ] && continue
    f="${f#./}"
    src="${DEPLOY_DIR}/${f}"
    if [ -f "$src" ]; then
        dest="${STAGING}/${f}"
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest"
        echo "    [include] $f"
    else
        echo "    [skip]     $f (not found)"
    fi
done < <(_list_includes)

# 按顶层条目打包，保留层次（不用「.»，减少 ./ 前缀差异）
mapfile -t _tops < <(find "$STAGING" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
tar -C "$STAGING" -czf "$TAR_PATH" "${_tops[@]}"
rm -rf "$STAGING"

echo ""
echo "[OK] Packed: $TAR_NAME"
echo "     Size:  $(du -h "$TAR_PATH" | cut -f1)"
