#!/usr/bin/env bash
# channel/registry.sh — 部署通道注册器（kind × channel 矩阵的 channel 轴，v2）
#
# 职责（契约见 project-configs/CHANNEL-CONTRACT.md）：
#   1. 解析 DEPLOY_CHANNEL（native | baota | docker），兼容旧 BAOTA_MODE 布尔开关
#   2. source 恰好一个通道目录下的 channel.sh（channel/<name>/channel.sh）
#   3. 能力断言：逐个核对统一动词，缺失即 fail-fast（宁可不部署，不带病运行）
#
# 用法（deploy.sh 中，service-ops.sh 之后）：
#   source "$SCRIPT_DIR/channel/registry.sh"
#   load_deploy_channel "$SCRIPT_DIR"
#
# Depends on: BAOTA_MODE, DEPLOY_CHANNEL（来自 deploy.env.*），err/ok/log（common.sh）

# ── 统一动词清单（新增动词：此处 + 各通道 channel.sh + CHANNEL-CONTRACT.md 同步）──
_CHANNEL_REQUIRED_VERBS=(
    channel_name
    channel_supported_kinds
    channel_wants_host_venv
    channel_routing_sync
    channel_frontend_prepare
    channel_frontend_preserve
    channel_frontend_restore
    channel_frontend_finalize
    channel_python_install
    channel_python_restart
    channel_java_install
    channel_java_restart
    channel_service_running
    channel_service_restart
    channel_status
    channel_logs
)

# ── 解析通道（兼容 BAOTA_MODE 布尔开关）──
resolve_deploy_channel() {
    if [ -n "${DEPLOY_CHANNEL:-}" ]; then
        case "$DEPLOY_CHANNEL" in
            native|baota|docker) echo "$DEPLOY_CHANNEL" ; return 0 ;;
            *)
                err "非法 DEPLOY_CHANNEL='$DEPLOY_CHANNEL'（可选: native | baota | docker）"
                return 1
                ;;
        esac
    fi
    # 兼容：旧开关 BAOTA_MODE=1 → baota；未设 → native
    if [ "${BAOTA_MODE:-0}" = "1" ]; then
        echo "baota"
    else
        echo "native"
    fi
}

# ── 加载唯一通道 + 能力断言 ──
load_deploy_channel() {
    local script_dir="${1:-$SCRIPT_DIR}"
    local chan
    chan=$(resolve_deploy_channel) || exit 1
    DEPLOY_CHANNEL="$chan"
    export DEPLOY_CHANNEL

    # 互斥约束：docker 与宝塔不共存（用户 2026-10-20 定）
    if [ "$chan" = "docker" ] && [ "${BAOTA_MODE:-0}" = "1" ]; then
        warn "DEPLOY_CHANNEL=docker 与 BAOTA_MODE=1 冲突：忽略 BAOTA_* 配置（docker 与宝塔不共存）"
    fi

    local chan_file="$script_dir/channels/${chan}.sh"
    if [ ! -f "$chan_file" ]; then
        err "通道文件不存在: $chan_file"
        exit 1
    fi
    # shellcheck source=channels/baota.sh
    source "$chan_file"

    # 能力断言：缺动词 = 通道实现不完整，fail-fast
    local missing=""
    local verb
    for verb in "${_CHANNEL_REQUIRED_VERBS[@]}"; do
        if ! declare -F "$verb" >/dev/null 2>&1; then
            missing="$missing $verb"
        fi
    done
    if [ -n "$missing" ]; then
        err "通道 [$chan] 缺少统一动词:$missing"
        err "  契约见 project-configs/CHANNEL-CONTRACT.md"
        exit 1
    fi

    log "部署通道: $chan ($(channel_name)) | 支持 kind: $(channel_supported_kinds)"
}
