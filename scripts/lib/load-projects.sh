#!/usr/bin/env bash
# scripts/lib/load-projects.sh — 从 projects.json 加载项目清单
# 用法: source scripts/lib/load-projects.sh
# 设置变量: PROJECT_IDS, DEPLOY_PATH[id], ARTIFACT[id], SERVICES[id], HEALTH_URL[id]

_load_projects() {
    local script_dir deploy_dir projects_file

    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    deploy_dir="$(dirname "$(dirname "$script_dir")")"

    # 定位 projects.json
    projects_file="${PROJECTS_FILE:-}"
    if [ -z "$projects_file" ]; then
        for f in "$deploy_dir/projects.json" \
                 "$DIST_ROOT/projects.json" \
                 "/www/wwwroot/project/uploads/dist/projects.json"; do
            [ -f "$f" ] && projects_file="$f" && break
        done
    fi

    if [ -z "$projects_file" ] || [ ! -f "$projects_file" ]; then
        echo "[ERR] projects.json not found" >&2
        echo "[ERR] Run: python3 scripts/sync-projects.py" >&2
        return 1
    fi

    # 解析优先级: WORKSPACE_ROOT env > json workspaceRoot > deploy 父目录
    local ws_root="${WORKSPACE_ROOT:-}"
    if [ -z "$ws_root" ]; then
        ws_root=$(_json_field "$projects_file" workspaceRoot)
    fi
    if [ -z "$ws_root" ] || [ "$ws_root" = '""' ]; then
        ws_root="$(dirname "$deploy_dir")"
    fi

    local proj_base="${PROJECT_BASE:-}"
    if [ -z "$proj_base" ]; then
        proj_base=$(_json_field "$projects_file" projectBase)
    fi
    [ -z "$proj_base" ] && proj_base="/www/wwwroot/project"

    # 导出全局变量
    export PROJECTS_FILE="$projects_file"
    export WORKSPACE_ROOT="$ws_root"
    export PROJECT_BASE="$proj_base"

    # 加载项目列表
    PROJECT_IDS=$(_json_project_ids "$projects_file")

    # 为每个项目生成关联数组
    declare -gA DEPLOY_PATH ARTIFACT_NAME SERVICES HEALTH_URL NGINX_RELOAD DEPLOY_HOOK PROJECT_KIND PROJECT_DISPLAY_NAME

    for id in $PROJECT_IDS; do
        DEPLOY_PATH[$id]="${PROJECT_BASE}/$(_json_project_field "$projects_file" "$id" deployPath)"
        ARTIFACT_NAME[$id]=$(_json_project_field "$projects_file" "$id" build.artifact)
        SERVICES[$id]=$(_json_project_field "$projects_file" "$id" services | tr -d '[]"' | sed 's/,/ /g')
        HEALTH_URL[$id]=$(_json_project_field "$projects_file" "$id" healthUrl)
        NGINX_RELOAD[$id]=$(_json_project_field "$projects_file" "$id" nginxReload)
        DEPLOY_HOOK[$id]=$(_json_project_field "$projects_file" "$id" deployHook)
        PROJECT_KIND[$id]=$(_json_project_field "$projects_file" "$id" kind)
        PROJECT_DISPLAY_NAME[$id]=$(_json_project_field "$projects_file" "$id" displayName)
    done

    return 0
}

# 辅助：用 jq 或 python3 读 JSON 字段
_json_field() {
    local file="$1" key="$2"
    if command -v jq &>/dev/null; then
        jq -r ".${key} // empty" "$file" 2>/dev/null
    else
        python3 -c "import json; d=json.load(open('$file')); print(d.get('$key',''))" 2>/dev/null
    fi
}

_json_project_ids() {
    local file="$1"
    if command -v jq &>/dev/null; then
        jq -r '.projects[] | select(.enabled==true) | .id' "$file" 2>/dev/null
    else
        python3 -c "
import json
d=json.load(open('$file'))
for p in d.get('projects',[]):
    if p.get('enabled'): print(p['id'])
" 2>/dev/null
    fi
}

_json_project_field() {
    local file="$1" id="$2" field="$3"
    if command -v jq &>/dev/null; then
        jq -r ".projects[] | select(.id==\"$id\") | .${field} // empty" "$file" 2>/dev/null
    else
        python3 -c "
import json
d=json.load(open('$file'))
for p in d.get('projects',[]):
    if p.get('id')=='$id':
        v=p
        for k in '${field}'.split('.'):
            v=v.get(k,'') if isinstance(v,dict) else ''
        print(v)
        break
" 2>/dev/null
    fi
}

# 自动执行
_load_projects
