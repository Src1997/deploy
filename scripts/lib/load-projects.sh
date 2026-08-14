#!/usr/bin/env bash
# scripts/lib/load-projects.sh — Load project list from TOML configs via config_loader.py
#
# Uses config_loader.py to read project-configs/*.toml directly (no projects.json).
# Sets: PROJECT_IDS, DEPLOY_PATH[id], ARTIFACT_NAME[id], SERVICES[id],
#       HEALTH_URL[id], NGINX_RELOAD[id], DEPLOY_HOOK[id], PROJECT_KIND[id],
#       PROJECT_DISPLAY_NAME[id], PUBLIC_URL[id], PROJECT_ROOT[id],
#       VENV_SHARED[id], PROJECT_ID[id]
# Also sets: WORKSPACE_ROOT, PROJECT_BASE

_load_projects() {
    local script_dir config_loader
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    config_loader="$script_dir/config_loader.py"

    if [ ! -f "$config_loader" ]; then
        echo "[ERR] config_loader.py not found: $config_loader" >&2
        return 1
    fi

    # Save env overrides (eval will set these from TOML)
    local _ws="${WORKSPACE_ROOT:-}" _pb="${PROJECT_BASE:-}"

    # Load project data from TOML configs
    eval "$(python3 "$config_loader" --format bash-eval)" || {
        echo "[ERR] Failed to parse project configs" >&2
        return 1
    }

    # Restore env overrides if they were set
    [ -n "$_ws" ] && WORKSPACE_ROOT="$_ws"
    [ -n "$_pb" ] && PROJECT_BASE="$_pb"

    # Fallback: if WORKSPACE_ROOT is empty, derive from deploy dir
    if [ -z "$WORKSPACE_ROOT" ]; then
        local deploy_dir
        deploy_dir="$(dirname "$(dirname "$script_dir")")"
        WORKSPACE_ROOT="$(dirname "$deploy_dir")"
    fi

    export WORKSPACE_ROOT PROJECT_BASE
    return 0
}

_load_projects
