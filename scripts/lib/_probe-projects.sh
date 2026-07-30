#!/usr/bin/env bash
# scripts/lib/_probe-projects.sh — 验证 projects.json 加载
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载
# shellcheck source=load-projects.sh
source "$script_dir/load-projects.sh"

echo "WorkspaceRoot: $WORKSPACE_ROOT"
echo "ProjectBase:    $PROJECT_BASE"
echo "ProjectsFile:   $PROJECTS_FILE"
echo "Projects:"

expected="financial-web financial-api official-site deepquant-web deepquant-backend"
fail=0
count=0
for id in $PROJECT_IDS; do
    count=$((count + 1))
    src="${WORKSPACE_ROOT}/${id}"
    # sourcePath from json via python/jq helper already loaded into DEPLOY_PATH;
    # re-read sourcePath for display
    sp=$(_json_project_field "$PROJECTS_FILE" "$id" sourcePath)
    src_abs="${WORKSPACE_ROOT}/${sp}"
    exists="MISSING"
    [ -d "$src_abs" ] && exists="OK"
    echo "  [$exists] id=$id  kind=${PROJECT_KIND[$id]}  src=$sp  deploy=${DEPLOY_PATH[$id]}  artifact=${ARTIFACT_NAME[$id]}"
    if [ -z "${DEPLOY_PATH[$id]:-}" ]; then
        echo "FAIL: empty DEPLOY_PATH for $id" >&2
        fail=1
    fi
    if [[ "${DEPLOY_PATH[$id]}" != "${PROJECT_BASE}/"* ]]; then
        echo "FAIL: DEPLOY_PATH should start with PROJECT_BASE for $id" >&2
        fail=1
    fi
done

for want in $expected; do
    found=0
    for id in $PROJECT_IDS; do
        [ "$id" = "$want" ] && found=1 && break
    done
    if [ "$found" -eq 0 ]; then
        echo "FAIL: missing project id: $want" >&2
        fail=1
    fi
done

if [ "$count" -lt 5 ]; then
    echo "FAIL: expected >=5 enabled projects, got $count" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: projects.json probe" >&2
    exit 1
fi

echo ""
echo "PASS: projects.json loaded ($count projects from json)"
