#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# 07-clone-source-data.sh — 【可选】从已验证的源站克隆业务数据到新部署机
#
# 定位：这是加速器，不是部署必需步骤。工具箱主路线 = seed 完整、新机零依赖开箱即用
# （导航节点 required_capability / 品牌 / EA 配置等已入种子）。只有想完整复制某个
# 源站的运营态（Admin 长期编辑过的配置、用户、历史数据）时才用本脚本。
# 新服务器没有任何可克隆源站时 → 跳过本脚本，部署即可正常工作。
#
# 用法（在本地、有源/目标 ssh 别名的机器上执行，不是在服务器上）：
#   bash 07-clone-source-data.sh --from serverB --to serverC \
#        --source-env deploy.env.server-b --target-env deploy.env.server-c \
#        [--group core|full] [--tables t1,t2,...] [--dry-run] [--yes]
#
# 分组（--group）：
#   core（默认）—— 运营配置/账号/导航/MT5 账号映射：
#     quant_zc: fin_navigation_nodes fin_app_configs fin_users
#               fin_mega_menus fin_mega_menu_categories fin_mega_menu_links
#               fin_footer_columns fin_footer_links fin_external_links
#               fin_data_source_configs fin_signal_configs
#               fin_search_hot_keywords fin_news_keywords fin_home_feed_widgets
#               fin_mt5_accounts
#     quantdinger: qd_users
#   full —— core + 内容历史大表：
#     quant_zc: fin_mt5_deals fin_mt5_equity_samples fin_mt5_quotes
#               fin_mt5_snapshots fin_calendar_events fin_news_items
#
# 永不搬运：fin_sessions fin_audit_logs fin_crawl_* fin_script_runs
#          fin_signals bak*_ Backup 表（运行痕迹/临时备份）
#
# 行为：
#   - 目标表已存在 → TRUNCATE ... CASCADE（连带清 FK 引用表！）+ data-only 恢复
#   - 目标表不存在 → schema+data 全量恢复
#   - 每表恢复后精确 count 对比源站，不一致即报错
#   - 全部完成后重启目标机 financial-api + quantdinger-backend（清运行时缓存）
#   - 自检 /api/navigation/menu 的 allowedMenuIds 非空
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

log()  { echo -e "\033[36m[*]\033[0m $*"; }
ok()   { echo -e "\033[32m[OK]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }
err()  { echo -e "\033[31m[ERR]\033[0m $*" >&2; }

# ── 参数解析（支持 --key=value 和 --key value 两种形式）──
FROM_ALIAS="" TO_ALIAS="" SOURCE_ENV="" TARGET_ENV=""
GROUP="core" TABLES="" PROJECT="" ASSUME_YES=false DRY_RUN=false
_prev=""
for arg in "$@"; do
    if [ -n "$_prev" ]; then
        case "$_prev" in
            from)        FROM_ALIAS="$arg" ;;
            to)          TO_ALIAS="$arg" ;;
            source-env)  SOURCE_ENV="$arg" ;;
            target-env)  TARGET_ENV="$arg" ;;
            group)       GROUP="$arg" ;;
            tables)      TABLES="$arg" ;;
            project)     PROJECT="$arg" ;;
        esac
        _prev=""
        continue
    fi
    case "$arg" in
        --from=*)        FROM_ALIAS="${arg#*=}" ;;
        --to=*)          TO_ALIAS="${arg#*=}" ;;
        --source-env=*)  SOURCE_ENV="${arg#*=}" ;;
        --target-env=*)  TARGET_ENV="${arg#*=}" ;;
        --group=*)       GROUP="${arg#*=}" ;;
        --tables=*)      TABLES="${arg#*=}" ;;
        --project=*)     PROJECT="${arg#*=}" ;;
        --from|--to|--source-env|--target-env|--group|--tables|--project) _prev="${arg#--}" ;;
        --yes|-y)        ASSUME_YES=true ;;
        --dry-run)       DRY_RUN=true ;;
        *) err "未知参数: $arg"; exit 1 ;;
    esac
done

[ -n "$FROM_ALIAS" ] || { err "缺少 --from=<源站ssh别名>"; exit 1; }
[ -n "$TO_ALIAS" ]   || { err "缺少 --to=<目标站ssh别名>"; exit 1; }

# 环境文件缺省：按别名推断 deploy.env.server-<x>（serverB/server-b → server-b）
alias_env_suffix() { echo "${1#server}" | tr 'A-Z' 'a-z'; }
if [ -z "$SOURCE_ENV" ]; then
    SOURCE_ENV="$DEPLOY_ROOT/deploy.env.server-$(alias_env_suffix "$FROM_ALIAS")"
fi
if [ -z "$TARGET_ENV" ]; then
    TARGET_ENV="$DEPLOY_ROOT/deploy.env.server-$(alias_env_suffix "$TO_ALIAS")"
fi
[ -f "$SOURCE_ENV" ] || { err "源站环境文件不存在: $SOURCE_ENV"; exit 1; }
[ -f "$TARGET_ENV" ] || { err "目标站环境文件不存在: $TARGET_ENV"; exit 1; }

# 读 env（剥 \r；值可能带单引号）
read_env_var() { # $1=env文件 $2=变量名
    grep -E "^${2}=" "$1" | head -1 | cut -d= -f2- | tr -d '\r' | sed "s/^'//;s/'$//"
}
SRC_PG_USER=$(read_env_var "$SOURCE_ENV" PG_USER);     SRC_PG_PASS=$(read_env_var "$SOURCE_ENV" PG_PASSWORD)
TGT_PG_USER=$(read_env_var "$TARGET_ENV" PG_USER);    TGT_PG_PASS=$(read_env_var "$TARGET_ENV" PG_PASSWORD)
[ -n "$SRC_PG_PASS" ] || { err "源站 PG_PASSWORD 为空"; exit 1; }
[ -n "$TGT_PG_PASS" ] || { err "目标站 PG_PASSWORD 为空"; exit 1; }

# ── 表清单（配置化：项目配置文件 project-configs/<project>/clone-tables.conf）──
# conf 格式:  <组名>: <库> <表1> <表2> ...
# --tables 传入时优先于 conf；此时按 qd_* → quantdinger、其余 → quant_zc 路由
PROJECT_CONF=""
if [ -n "$PROJECT" ]; then
    PROJECT_CONF="$DEPLOY_ROOT/project-configs/$PROJECT/clone-tables.conf"
    [ -f "$PROJECT_CONF" ] || { err "项目配置不存在: $PROJECT_CONF"; exit 1; }
elif [ -z "$TABLES" ]; then
    err "需指定 --project=<项目名>（读 project-configs/<project>/clone-tables.conf）或 --tables=<表清单>"
    exit 1
fi

# 解析 conf → TABLE_SPECS（"库.表" 列表，仅取匹配 GROUP 的行）
TABLE_SPECS=""
if [ -n "$PROJECT_CONF" ]; then
    while IFS= read -r line; do
        case "$line" in
            \#*|"") continue ;;
        esac
        g="${line%%:*}"
        rest="${line#*:}"
        if [ "$g" = "$GROUP" ]; then
            db=$(echo "$rest" | awk '{print $1}')
            for t in $(echo "$rest" | awk '{$1=""; print $0}'); do
                TABLE_SPECS="$TABLE_SPECS $db.$t"
            done
        fi
    done < "$PROJECT_CONF"
    [ -n "$(echo $TABLE_SPECS | tr -d ' ')" ] || { err "conf 中没有 group=$GROUP 的行"; exit 1; }
fi

# --tables 覆盖模式（临时指定表清单，库按前缀路由）
if [ -n "$TABLES" ]; then
    TABLE_SPECS=""
    for t in $(echo "$TABLES" | tr ',' ' '); do
        case "$t" in qd_*) TABLE_SPECS="$TABLE_SPECS quantdinger.$t" ;; *) TABLE_SPECS="$TABLE_SPECS quant_zc.$t" ;; esac
    done
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  克隆业务数据: $FROM_ALIAS → $TO_ALIAS (group=$GROUP${PROJECT:+, project=$PROJECT})"
echo "═══════════════════════════════════════════════════════════"
log "表清单:$TABLE_SPECS"
$DRY_RUN && { ok "[DryRun] 校验通过，未执行任何变更"; exit 0; }

if ! $ASSUME_YES; then
    warn "TRUNCATE ... CASCADE 会连带清空目标机 FK 引用表！确认目标机是刚部署/可覆盖状态。"
    printf "  确认继续？输入 yes: "
    read -r confirm
    [ "$confirm" = "yes" ] || { err "已取消"; exit 1; }
fi

TMPD="$DEPLOY_ROOT/dist/tmp_clone.$$"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT
FAILED=0

# ── FK 连带自愈：TRUNCATE CASCADE 会连带清引用表，自动把它们拉进清单 ──
# 逐个表查目标库的 FK 依赖（confrelid=被引用表），依赖表若不在清单则补入，
# 避免「连带清了却没人恢复」的坑（fin_mt5_accounts CASCADE 清空 quotes 等）。
_expand=0
while :; do
    ADDED=0
    for spec in $TABLE_SPECS; do
        db="${spec%%.*}"; t="${spec#*.}"
        deps=$(ssh -o ConnectTimeout=20 "$TO_ALIAS" \
            "PGPASSWORD='$TGT_PG_PASS' psql -U '$TGT_PG_USER' -h localhost -d '$db' -Atc \"SELECT confrelid::regclass::text FROM pg_constraint WHERE confrelid='$t'::regclass AND contype='f';\" 2>/dev/null || true")
        for d in $deps; do
            case "$d" in
                *[!a-z0-9_]*|"") continue ;;  # 跳过 regclass 带 schema/异常格式
            esac
            if ! echo " $TABLE_SPECS " | grep -q " $db.$d "; then
                TABLE_SPECS="$TABLE_SPECS $db.$d"
                ADDED=$((ADDED+1))
                log "FK 连带自愈: $t 的依赖表 $d 已自动加入克隆清单"
            fi
        done
    done
    [ "$ADDED" -eq 0 ] && break
    _expand=$((_expand+1))
    [ "$_expand" -gt 5 ] && { err "FK 依赖展开超过 5 轮，疑似循环引用，中止"; exit 1; }
done
log "最终表清单:$TABLE_SPECS"

for spec in $TABLE_SPECS; do
    db="${spec%%.*}"
    t="${spec#*.}"
    log "── $db.$t"
    dump="$TMPD/${t}.sql.gz"

    # 1. 源站精确行数
    src_count=$(ssh -o ConnectTimeout=20 "$FROM_ALIAS" \
        "PGPASSWORD='$SRC_PG_PASS' psql -U '$SRC_PG_USER' -h localhost -d '$db' -Atc 'SELECT count(*) FROM $t;'" 2>/dev/null || echo "N/A")
    if [ "$src_count" = "N/A" ]; then
        err "    源站查询失败（表不存在或连接失败），跳过 $t"; FAILED=$((FAILED+1)); continue
    fi

    # 2. 目标站表是否存在
    tgt_exists=$(ssh -o ConnectTimeout=20 "$TO_ALIAS" \
        "PGPASSWORD='$TGT_PG_PASS' psql -U '$TGT_PG_USER' -h localhost -d '$db' -Atc \"SELECT count(*) FROM information_schema.tables WHERE table_name='$t';\"" 2>/dev/null || echo 0)

    # 3. dump（存在→data-only；不存在→schema+data）
    if [ "$tgt_exists" = "1" ]; then
        ssh -o ConnectTimeout=20 "$FROM_ALIAS" \
            "PGPASSWORD='$SRC_PG_PASS' pg_dump -U '$SRC_PG_USER' -h localhost -d '$db' --no-owner --no-privileges -t '$t' --data-only | gzip" > "$dump"
    else
        ssh -o ConnectTimeout=20 "$FROM_ALIAS" \
            "PGPASSWORD='$SRC_PG_PASS' pg_dump -U '$SRC_PG_USER' -h localhost -d '$db' --no-owner --no-privileges -t '$t' | gzip" > "$dump"
    fi
    [ -s "$dump" ] || { err "    dump 为空，跳过 $t"; FAILED=$((FAILED+1)); continue; }

    # 4. 上传 + 恢复
    ssh -o ConnectTimeout=20 "$TO_ALIAS" "cat > /tmp/clone_tbl.gz" < "$dump"
    if [ "$tgt_exists" = "1" ]; then
        ssh -o ConnectTimeout=20 "$TO_ALIAS" \
            "PGPASSWORD='$TGT_PG_PASS' psql -U '$TGT_PG_USER' -h localhost -d '$db' -c 'TRUNCATE $t CASCADE;' >/dev/null && gunzip -c /tmp/clone_tbl.gz | PGPASSWORD='$TGT_PG_PASS' psql -U '$TGT_PG_USER' -h localhost -d '$db' 2>&1 | grep -c ERROR || true" > "$TMPD/rc.txt"
    else
        ssh -o ConnectTimeout=20 "$TO_ALIAS" \
            "gunzip -c /tmp/clone_tbl.gz | PGPASSWORD='$TGT_PG_PASS' psql -U '$TGT_PG_USER' -h localhost -d '$db' 2>&1 | grep -c ERROR || true" > "$TMPD/rc.txt"
    fi
    ssh -o ConnectTimeout=20 "$TO_ALIAS" "rm -f /tmp/clone_tbl.gz"

    err_lines=$(cat "$TMPD/rc.txt" | tail -1)
    [ "$err_lines" = "0" ] || { err "    恢复出现 $err_lines 条 ERROR"; FAILED=$((FAILED+1)); }

    # 5. 目标站精确行数对比
    tgt_count=$(ssh -o ConnectTimeout=20 "$TO_ALIAS" \
        "PGPASSWORD='$TGT_PG_PASS' psql -U '$TGT_PG_USER' -h localhost -d '$db' -Atc 'SELECT count(*) FROM $t;'" 2>/dev/null || echo "N/A")
    if [ "$src_count" = "$tgt_count" ]; then
        ok "    $t: $src_count 行（源/目标一致）"
    else
        err "    $t: 源 $src_count vs 目标 $tgt_count 行数不一致"; FAILED=$((FAILED+1))
    fi
done

# ── post-override：克隆后重放机器级差异（如 C 的品牌=卓筹，防被源站值覆盖）──
# SQL 含单引号，经 base64 传输避免 ssh 引号嵌套问题
if [ -n "$PROJECT_CONF" ]; then
    grep '^post-override:' "$PROJECT_CONF" | cut -d: -f2- | while IFS= read -r sql; do
        [ -n "$sql" ] || continue
        log "post-override: $sql"
        b64=$(printf '%s' "$sql" | base64 | tr -d '\n')
        ssh -o ConnectTimeout=20 "$TO_ALIAS" \
            "echo $b64 | base64 -d | PGPASSWORD='$TGT_PG_PASS' psql -U '$TGT_PG_USER' -h localhost -d quant_zc >/dev/null 2>&1" || \
            warn "post-override 执行失败: $sql"
    done
fi

# ── 重启目标机服务（清运行时缓存）──
log "重启目标机 financial-api / quantdinger-backend（清 runtime-config 缓存）..."
ssh -o ConnectTimeout=20 "$TO_ALIAS" \
    "/www/server/panel/pyenv/bin/supervisorctl restart financial-api quantdinger-backend >/dev/null 2>&1 || supervisorctl restart financial-api quantdinger-backend" 2>/dev/null || \
    warn "supervisorctl 重启失败，请手动重启两个后端（直接 SQL 恢复不会清 runtime-config 缓存）"
sleep 5

# ── 菜单自检 ──
log "自检 /api/navigation/menu ..."
menu_n=$(ssh -o ConnectTimeout=20 "$TO_ALIAS" \
    "curl -s --max-time 10 'http://127.0.0.1:5001/api/navigation/menu'" 2>/dev/null | \
    grep -o '"allowedMenuIds":\[[^]]*\]' | grep -o ',' | wc -l)
menu_n=$((menu_n + 1))  # 逗号数+1 ≈ 元素数（空数组时 grep 不到 → 0+1，下面再校准）
if [ "$menu_n" -gt 1 ]; then
    ok "allowedMenuIds 约 $menu_n 项（>1 即菜单已恢复）"
else
    warn "allowedMenuIds 仍为空——确认 fin_navigation_nodes.required_capability 已有值且 financial-api 已重启"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    ok "═══ 克隆完成：全部表一致，菜单自检通过 ═══"
else
    err "═══ 克隆完成，但有 $FAILED 张表异常，请核对上方输出 ═══"
    exit 1
fi
