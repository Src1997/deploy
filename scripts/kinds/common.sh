#!/usr/bin/env bash
# kind/_common.sh — kind 层公共设施 + 按 kind 分发（v2）
#
# ★目录分层（用户定）：kind = 前端 / 后端两大类，后端再按语言分：
#   kind/_common.sh         本文件：跨类公共（找包、健康门）+ deploy_by_id 分发
#   kind/frontend/_common.sh  前端公共流程（构建工具差异走 TOML build.*，零脚本分支）
#   kind/backend/_common.sh   后端公共（.env 渲染）
#   kind/backend/python.sh    Python 后端
#   kind/backend/java.sh      Java 后端
# 项目差异一律在 project-configs/<name>/project.toml（配置驱动），不进脚本。
#
# Provides: deploy_by_id, _kind_find_artifact, _kind_health_gate
# Depends on: 各组件数组（load-projects）、channel_*（registry 加载）、
#             find_file, check_package_freshness（core/common.sh）、health_check

# -- 找包 + 新鲜度检查（双端共用）--
_kind_find_artifact() {
    local id="$1"
    local tar_pat="${ARTIFACT_NAME[$id]:-}"
    [ -z "$tar_pat" ] && { err "TOML 配置缺少 $id.build.artifact(Pattern)"; return 1; }
    local tar
    tar=$(find_file "$tar_pat")
    [ -z "$tar" ] && { err "未找到 $tar_pat"; err "请先本地执行: ./scripts/build.ps1 $id"; return 1; }
    # ★freshness 日志必须走 stderr：本函数 stdout 只允许输出 tar 路径（被 $() 捕获）
    check_package_freshness "$tar" "$id" >&2
    echo "$tar"
}

# -- 部署后健康门（公共闭环：失败计部署失败、提示可回滚）--
_kind_health_gate() {
    local id="$1"
    [ -n "${NO_RESTART}" ] && true
    $NO_RESTART && return 0
    [ -z "${HEALTH_URL[$id]:-}" ] && return 0
    sleep 3
    local health_rc=0
    health_check "$id" "${HEALTH_URL[$id]}" || health_rc=1
    if [ "$health_rc" -eq 1 ]; then
        err "$id 部署后健康检查未通过，本次部署计为失败: ${HEALTH_URL[$id]}"
        warn "  代码已更新但服务未就绪——部署前备份已保留，可回滚: bash deploy.sh $id --rollback"
        return 1
    fi
    return 0
}

# -- 按 kind 分发（通道能力校验：kind 不在通道支持列表即报错）--
deploy_by_id() {
    local id="$1"
    if [ -z "${DEPLOY_PATH[$id]:-}" ]; then
        err "未知项目或不在 TOML 配置中: $id"
        return 1
    fi
    local kind="${PROJECT_KIND[$id]}"
    local supported
    supported=$(channel_supported_kinds)
    case " $supported " in
        *" $kind "*)
            case "$kind" in
                frontend) deploy_frontend "$id" ;;
                python)   deploy_python "$id" ;;
                java)     deploy_java "$id" ;;
            esac
            ;;
        *)
            err "通道 [$(channel_name)] 不支持 kind: $kind ($id)——支持: $supported"
            err "  换通道（DEPLOY_CHANNEL / --channel）或为该 kind 扩展通道实现（CHANNEL-CONTRACT.md）"
            return 1
            ;;
    esac
}
