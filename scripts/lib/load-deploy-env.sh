#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# 公共：加载 deploy.env
#
# 用法：
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=lib/load-deploy-env.sh
#   source "$SCRIPT_DIR/lib/load-deploy-env.sh"
#   load_deploy_env "$SCRIPT_DIR"
# ═══════════════════════════════════════════════════════════════

load_deploy_env() {
    local script_dir="${1:-}"
    local f deploy_root=""

    if [ -n "$script_dir" ]; then
        deploy_root="$(cd "$script_dir/.." 2>/dev/null && pwd || true)"
    fi

    for f in "${DEPLOY_ENV_FILE:-}" \
             ${script_dir:+"$script_dir/../deploy.env"} \
             ${deploy_root:+"$deploy_root/deploy.env"} \
             ${script_dir:+"$script_dir/deploy.env"} \
             "$(pwd)/deploy.env" \
             "${HOME}/deploy-sandbox/deploy.env" \
             "/www/wwwroot/project/deploy.env"; do
        [ -n "$f" ] && [ -f "$f" ] || continue
        set -a
        # shellcheck disable=SC1090
        source "$f"
        set +a
        export DEPLOY_ENV_LOADED="$f"
        return 0
    done
    return 1
}

# 密码未配置时失败（--help / 只读探测不要调用）
require_deploy_secrets() {
    local missing=0
    if [ -z "${PG_PASSWORD:-}" ] || [ "${PG_PASSWORD}" = "CHANGE_ME" ]; then
        echo -e "\033[31m[ERR]\033[0m PG_PASSWORD 未配置。请: cp deploy.env.example deploy.env 并填写密码" >&2
        missing=1
    fi
    if [ -z "${REDIS_PASSWORD:-}" ] || [ "${REDIS_PASSWORD}" = "CHANGE_ME" ]; then
        echo -e "\033[31m[ERR]\033[0m REDIS_PASSWORD 未配置。请: cp deploy.env.example deploy.env 并填写密码" >&2
        missing=1
    fi
    if [ "$missing" -ne 0 ]; then
        echo -e "\033[33m[!]\033[0m 也可: export DEPLOY_ENV_FILE=/path/to/deploy.env" >&2
        [ -n "${DEPLOY_ENV_LOADED:-}" ] && echo -e "\033[33m[!]\033[0m 当前已加载: $DEPLOY_ENV_LOADED（但密码仍是占位符）" >&2
        return 1
    fi
    return 0
}
