#!/usr/bin/env bash
# lib/common.sh — Shared utilities for deploy.sh
#
# Provides: colors, logging, CRLF self-fix, script freshness check,
#           find_file, check_package_freshness
#
# This file is sourced by deploy.sh; it must not be executed directly.
# Depends on: PROJECT_BASE, PACKAGES_DIR, PKG_STALE_DAYS (all optional, have defaults).

# -- Colors --
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
log()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; }
hr()   { echo -e "${DIM}────────────────────────────────────────────────${NC}"; }
banner() { echo -e "\n${CYAN}═══════════════════════════════════════════════════════════${NC}"; echo -e "  ${BOLD}$*${NC}"; echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}\n"; }

# -- Script freshness check: warn if server scripts are stale --
# build.ps1 writes dist/.scripts-version with a timestamp; if the
# deploy.sh running now is older than that stamp, the server has
# newer scripts in dist/ that were not yet activated.
_check_script_freshness() {
    local script_dir candidate_dir version_file script_mtime version_ts
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" 2>/dev/null || return 0
    # Navigate up to the deploy.sh directory (this file is in lib/)
    script_dir="$(dirname "$script_dir")"

    for candidate_dir in "$script_dir" \
                         "$script_dir/.." \
                         "${PROJECT_BASE:-/www/wwwroot/project}/uploads/dist"; do
        version_file="$candidate_dir/.scripts-version"
        [ -f "$version_file" ] || continue
        script_mtime=$(stat -c %Y "${BASH_SOURCE[0]}" 2>/dev/null || stat -f %m "${BASH_SOURCE[0]}" 2>/dev/null || echo 0)
        version_ts=$(cat "$version_file" 2>/dev/null | tr -d '[:space:]')
        [ -z "$version_ts" ] && return 0
        local version_epoch
        version_epoch=$(date -d "$version_ts" +%s 2>/dev/null || echo 0)
        [ "$version_epoch" -eq 0 ] && return 0
        [ "$script_mtime" -eq 0 ] && return 0

        if [ "$version_epoch" -gt "$script_mtime" ]; then
            echo -e "\033[33m[!] WARNING: deploy scripts on this server are STALE.\033[0m" >&2
            echo -e "\033[33m[!] dist/.scripts-version: $version_ts\033[0m" >&2
            echo -e "\033[33m[!] This deploy.sh last modified: $(date -d "@$script_mtime" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'unknown')\033[0m" >&2
            echo -e "\033[33m[!] The dist/ directory contains newer scripts. Re-upload or run:\033[0m" >&2
            echo -e "\033[33m[!]   cp $candidate_dir/deploy.sh $script_dir/deploy.sh\033[0m" >&2
            echo -e "\033[33m[!]   cp $candidate_dir/detect-status.sh $script_dir/detect-status.sh\033[0m" >&2
            echo -e "\033[33m[!]   cp -r $candidate_dir/lib/* $script_dir/lib/ 2>/dev/null; true\033[0m" >&2
            echo "" >&2
            return 1
        fi
        return 0
    done
}

# -- Find latest package matching pattern --
find_file() {
    local pattern="$1" found
    found=$(ls -t "$PACKAGES_DIR"/$pattern 2>/dev/null | head -1)
    [ -n "$found" ] && [ -f "$found" ] && realpath "$found" || true
}

# -- Check package freshness: read VERSION from tar.gz and warn if stale --
check_package_freshness() {
    local tar="$1" id="${2:-unknown}"
    local version_line built_ts built_epoch now_epoch stale_seconds
    local stale_days="${PKG_STALE_DAYS:-7}"

    local version_content
    version_content=$(tar xzf "$tar" -O 2>/dev/null \
        --wildcards '*/VERSION' 'VERSION' 2>/dev/null || true)
    [ -z "$version_content" ] && return 0

    log "Package version ($id):"
    echo "$version_content" | while IFS= read -r line; do
        echo "    $line"
    done

    built_ts=$(echo "$version_content" | grep '^built=' | head -1 | cut -d= -f2- | tr -d '[:space:]')
    [ -z "$built_ts" ] && return 0

    # Convert YYYYMMDD-HHMMSS (pack.ps1 format) to YYYY-MM-DD HH:MM:SS
    local built_ts_parsed
    built_ts_parsed=$(echo "$built_ts" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)-\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
    [ -z "$built_ts_parsed" ] && built_ts_parsed="$built_ts"

    built_epoch=$(date -d "$built_ts_parsed" +%s 2>/dev/null || echo 0)
    [ "$built_epoch" -eq 0 ] && return 0
    now_epoch=$(date +%s 2>/dev/null || echo 0)
    [ "$now_epoch" -eq 0 ] && return 0

    stale_seconds=$((stale_days * 86400))
    local age_seconds=$((now_epoch - built_epoch))
    if [ "$age_seconds" -gt "$stale_seconds" ]; then
        local age_days=$((age_seconds / 86400))
        warn "$id package is STALE: built $age_days days ago ($built_ts)"
        warn "Rebuild locally: ./scripts/build.ps1 $id"
    fi
}
