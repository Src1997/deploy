#!/usr/bin/env bash
# scripts/lib/_probe-projects.sh — 验证 projects.json 加载
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载
source "$script_dir/load-projects.sh"

echo "WorkspaceRoot: $WORKSPACE_ROOT"
echo "ProjectBase:    $PROJECT_BASE"
echo "Projects:"

fail=0
for id in $PROJECT_IDS; do
    src="${WORKSPACE_ROOT}/$(grep -o "\"sourcePath\": *\"[^\"]*\"" "$PROJECTS_FILE" | head -1 | sed 's/.*: *"\(.*\)"/\1/')"
    # 简化：直接用 load-projects 的变量
    echo "  id=$id  kind=${PROJECT_KIND[$id]}  deploy=${DEPLOY_PATH[$id]}"
done

echo ""
echo "PASS: projects.json loaded"
