#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# 公共：加载 deploy.env
#
# 三套环境文件（由 DEPLOY_TARGET 环境变量选择）：
#   DEPLOY_TARGET 未设置  → deploy.env           (本地/虚拟机)
#   DEPLOY_TARGET=server-a → deploy.env.server-a  (服务器 A)
#   DEPLOY_TARGET=server-b → deploy.env.server-b  (服务器 B)
#
# 也可通过 DEPLOY_ENV_FILE 直接指定路径（优先级最高）：
#   DEPLOY_ENV_FILE=/path/to/custom.env
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

    # Determine env file suffix based on DEPLOY_TARGET
    local suffix=""
    case "${DEPLOY_TARGET:-}" in
        server-a) suffix=".server-a" ;;
        server-b) suffix=".server-b" ;;
        "")       suffix="" ;;
        *)        suffix=".$DEPLOY_TARGET" ;;  # custom target
    esac
    local env_name="deploy.env${suffix}"

    # Build search list: DEPLOY_ENV_FILE first, then target-specific, then default
    for f in "${DEPLOY_ENV_FILE:-}" \
             ${script_dir:+"$script_dir/../${env_name}"} \
             ${deploy_root:+"$deploy_root/${env_name}"} \
             ${script_dir:+"$script_dir/${env_name}"} \
             "$(pwd)/${env_name}" \
             "${HOME}/deploy-sandbox/${env_name}" \
             "/www/wwwroot/project/${env_name}" \
             ${script_dir:+"$script_dir/../deploy.env"} \
             ${deploy_root:+"$deploy_root/deploy.env"} \
             ${script_dir:+"$script_dir/deploy.env"} \
             "$(pwd)/deploy.env" \
             "${HOME}/deploy-sandbox/deploy.env" \
             "/www/wwwroot/project/deploy.env"; do
        [ -n "$f" ] && [ -f "$f" ] || continue
        # Preserve env vars that were explicitly set before sourcing deploy.env
        local _dry_run="${DEPLOY_DRY_RUN:-}"
        set -a
        # shellcheck disable=SC1090
        source "$f"
        set +a
        # Restore DRY_RUN if it was explicitly set in environment (overrides deploy.env)
        [ -n "$_dry_run" ] && DEPLOY_DRY_RUN="$_dry_run"
        export DEPLOY_ENV_LOADED="$f"
        return 0
    done
    return 1
}

# 密码未配置时失败（--help / 只读探测不要调用）
# PG_PASSWORD 必须配置；REDIS_PASSWORD 可选（部分服务器 Redis 无密码）
require_deploy_secrets() {
    local missing=0
    if [ -z "${PG_PASSWORD:-}" ] || [ "${PG_PASSWORD}" = "CHANGE_ME" ]; then
        echo -e "\033[31m[ERR]\033[0m PG_PASSWORD 未配置。请: cp deploy.env.example deploy.env 并填写密码" >&2
        missing=1
    fi
    if [ "${REDIS_PASSWORD:-}" = "CHANGE_ME" ]; then
        echo -e "\033[31m[ERR]\033[0m REDIS_PASSWORD 仍为 CHANGE_ME 占位符。请: cp deploy.env.example deploy.env 并填写密码（无密码则留空）" >&2
        missing=1
    fi
    if [ "$missing" -ne 0 ]; then
        echo -e "\033[33m[!]\033[0m 也可: export DEPLOY_ENV_FILE=/path/to/deploy.env" >&2
        echo -e "\033[33m[!]\033[0m 或: export DEPLOY_TARGET=server-a  # 加载 deploy.env.server-a" >&2
        [ -n "${DEPLOY_ENV_LOADED:-}" ] && echo -e "\033[33m[!]\033[0m 当前已加载: $DEPLOY_ENV_LOADED（但密码仍是占位符）" >&2
        return 1
    fi
    return 0
}
