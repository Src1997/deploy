#!/usr/bin/env bash
# ================================================================
# Common: load deploy.env
#
# Three env file sets (selected by DEPLOY_TARGET env var):
#   DEPLOY_TARGET unset     -> deploy.env           (local)
#   DEPLOY_TARGET=vm        -> deploy.env.vm        (virtual machine)
#   DEPLOY_TARGET=server-a  -> deploy.env.server-a  (server A)
#   DEPLOY_TARGET=server-b  -> deploy.env.server-b  (server B)
#
# Or specify path directly via DEPLOY_ENV_FILE (highest priority):
#   DEPLOY_ENV_FILE=/path/to/custom.env
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=lib/load-deploy-env.sh
#   source "$SCRIPT_DIR/lib/load-deploy-env.sh"
#   load_deploy_env "$SCRIPT_DIR"
# ================================================================

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
        # Strip CRLF (\r) before sourcing - Windows-edited env files
        # would inject \r into variable values causing garbled errors
        # shellcheck disable=SC1090
        source <(sed 's/\r$//' "$f")
        set +a
        # Restore DRY_RUN if it was explicitly set in environment (overrides deploy.env)
        [ -n "$_dry_run" ] && DEPLOY_DRY_RUN="$_dry_run"
        export DEPLOY_ENV_LOADED="$f"
        return 0
    done
    return 1
}

# Fail when secrets are not configured (do not call from --help / read-only probes)
# PG_PASSWORD is required; REDIS_PASSWORD is optional (some servers have no Redis password)
require_deploy_secrets() {
    local missing=0
    if [ -z "${PG_PASSWORD:-}" ] || [ "${PG_PASSWORD}" = "CHANGE_ME" ]; then
        echo -e "\033[31m[ERR]\033[0m PG_PASSWORD not configured. Please: cp deploy.env.example deploy.env and fill in the password" >&2
        missing=1
    fi
    if [ "${REDIS_PASSWORD:-}" = "CHANGE_ME" ]; then
        echo -e "\033[31m[ERR]\033[0m REDIS_PASSWORD is still the CHANGE_ME placeholder. Please: cp deploy.env.example deploy.env and fill in the password (leave empty if no password)" >&2
        missing=1
    fi
    if [ "$missing" -ne 0 ]; then
        echo -e "\033[33m[!]\033[0m Alternatively: export DEPLOY_ENV_FILE=/path/to/deploy.env" >&2
        echo -e "\033[33m[!]\033[0m Or: export DEPLOY_TARGET=server-a  # load deploy.env.server-a" >&2
        [ -n "${DEPLOY_ENV_LOADED:-}" ] && echo -e "\033[33m[!]\033[0m Currently loaded: $DEPLOY_ENV_LOADED (but password is still placeholder)" >&2
        return 1
    fi
    return 0
}
