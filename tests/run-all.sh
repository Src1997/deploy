#!/usr/bin/env bash
# ================================================================
# tests/run-all.sh — L1 本地快速回归（秒级，无需服务器）
#
# 查什么（按"抓真实故障"设计，不做摆设检查）：
#   1. bash -n 全部 shell 脚本语法
#   2. ast 全部 python 脚本语法
#   3. config_loader check（TOML → manifest）
#   4. servers 清单非空（env 单源化回归点）
#   5. bash-eval 输出可 source + PROJECT_IDS 非空
#   6. CRLF 防线：脚本/TOML/env 模板不得带 \r
#      （实证坑：CRLF 的 \r 粘进 BAOTA_PANEL_URL → HTTP header 炸）
#   7. Python 依赖上界审计：>= 必须配 < 上界
#      （实证坑：mcp>=1.2.0 无上界 → 装成 2.x → FastMCP 改名 → MCP 崩）
#   8. .gitignore 密码防线
#
# ⚠️ 本脚本只能证明"语法与配置层"没问题。部署链路的真实回归
#    用 L2 黄金链路测试：tests/golden-path-vm.sh（在 VM 上跑）。
#
# 用法：
#   ./tests/run-all.sh                 # 用 PATH 里的 python3
#   PYTHON=/path/to/python ./tests/run-all.sh
#
# 退出码：0=全绿，非 0=存在失败项（失败项全部列出，不短路）
# ================================================================
set -uo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PYTHON:-python3}"
FAIL=0

pass() { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
hr()   { echo "────────────────────────────────────────────────"; }

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  deploy 工具箱 L1 本地回归（$DEPLOY_ROOT）"
echo "╚══════════════════════════════════════════════╝"
echo ""

echo "── 1/9 bash -n 语法校验 ──"
hr
SYNTAX_FAIL=0
for s in "$DEPLOY_ROOT"/scripts/*.sh \
         "$DEPLOY_ROOT"/scripts/core/*.sh "$DEPLOY_ROOT"/scripts/kind/*.sh "$DEPLOY_ROOT"/scripts/channel/*.sh \
         "$DEPLOY_ROOT"/scripts/ops/*.sh \
         "$DEPLOY_ROOT"/scripts/tools/*.sh \
         "$DEPLOY_ROOT"/tests/*.sh; do
    [ -f "$s" ] || continue
    if ! ERR=$(bash -n "$s" 2>&1); then
        bad "语法: ${s#$DEPLOY_ROOT/}"
        echo "$ERR" | sed 's/^/         /'
        SYNTAX_FAIL=1
    fi
done
[ "$SYNTAX_FAIL" -eq 0 ] && pass "全部 shell 脚本语法通过"

echo ""
echo "── 2/9 python ast 语法校验 ──"
hr
PY_FAIL=0
while IFS= read -r s; do
    if ! ERR=$("$PY" -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$s" 2>&1); then
        bad "语法: ${s#$DEPLOY_ROOT/}"
        echo "$ERR" | sed 's/^/         /'
        PY_FAIL=1
    fi
done < <(find "$DEPLOY_ROOT/scripts" "$DEPLOY_ROOT/tests" -name "*.py" -type f 2>/dev/null)
[ "$PY_FAIL" -eq 0 ] && pass "全部 python 脚本语法通过"

echo ""
echo "── 3/9 config_loader 校验 ──"
hr
CHECK_OUT=$(cd "$DEPLOY_ROOT/scripts/core" && "$PY" config_loader.py --format check 2>&1)
CHECK_RC=$?
if [ "$CHECK_RC" -eq 0 ]; then
    pass "config_loader check: $(echo "$CHECK_OUT" | head -1)"
else
    bad "config_loader check（退出码 $CHECK_RC）"
    echo "$CHECK_OUT" | sed 's/^/         /'
fi

echo ""
echo "── 4/9 servers 清单（env 单源化回归点）──"
hr
SERVERS_JSON=$(cd "$DEPLOY_ROOT/scripts/core" && "$PY" config_loader.py 2>/dev/null \
    | "$PY" -c "import json,sys; m=json.load(sys.stdin); print(' '.join(m['servers'].keys()))")
if [ -n "$SERVERS_JSON" ]; then
    pass "servers 非空: $SERVERS_JSON"
else
    bad "servers 清单为空（deploy.env.server-* 的 DOMAIN 都没读到？）"
fi

echo ""
echo "── 5/9 bash-eval 冒烟（load-projects.sh 依赖）──"
hr
BASH_EVAL_OUT=$(cd "$DEPLOY_ROOT/scripts/core" && "$PY" config_loader.py --format bash-eval 2>/dev/null)
if [ -n "$BASH_EVAL_OUT" ] && printf '%s\n' "$BASH_EVAL_OUT" | bash -c 'source /dev/stdin' 2>/dev/null; then
    pass "bash-eval 输出可被 bash source"
else
    bad "bash-eval 输出无法被 bash source"
fi
if [ -n "$BASH_EVAL_OUT" ] && echo "$BASH_EVAL_OUT" | grep -q "PROJECT_IDS=" &&
   ! echo "$BASH_EVAL_OUT" | grep -q "PROJECT_IDS=$"; then
    pass "PROJECT_IDS 非空"
else
    bad "PROJECT_IDS 为空或缺失"
fi

echo ""
echo "── 6/9 CRLF 防线（\\r 粘进 env 值会炸 HTTP header）──"
hr
CRLF_FAIL=0
while IFS= read -r f; do
    if grep -q $'\r' "$f" 2>/dev/null; then
        bad "CRLF: ${f#$DEPLOY_ROOT/}（转 LF: sed -i 's/\\r\$//' \"$f\"）"
        CRLF_FAIL=1
    fi
done < <(find "$DEPLOY_ROOT/scripts" "$DEPLOY_ROOT/tests" "$DEPLOY_ROOT/project-configs" \
             \( -name "*.sh" -o -name "*.py" -o -name "*.toml" \) -type f 2>/dev/null;
         find "$DEPLOY_ROOT" -maxdepth 1 -name "deploy.env*" -type f 2>/dev/null)
[ "$CRLF_FAIL" -eq 0 ] && pass "无 CRLF 污染"

echo ""
echo "── 7/9 Python 依赖上界审计（>= 必须配 <）──"
hr
PIN_FAIL=0
PIN_FILES=$(ls "$DEPLOY_ROOT"/*/pyproject.toml 2>/dev/null;
            find "$DEPLOY_ROOT/.." -maxdepth 3 \
                 \( -path "*/node_modules" -o -path "*/.venv" -o -path "*/.git" \) -prune -o \
                 \( -name "pyproject.toml" -o -name "requirements*.txt" \) -type f -print 2>/dev/null | sort -u)
while IFS= read -r f; do
    [ -f "$f" ] || continue
    # 匹配 name>=X.Y 形式且同行无 '<' 上界、无豁免标记
    # 豁免：requires-python、build-system requires（构建隔离自管版本）
    while IFS= read -r line; do
        bad "依赖无上界: ${f#$DEPLOY_ROOT/../} → $line"
        echo "         （加 <上界，或行尾注释 # unbounded-ok 豁免）"
        PIN_FAIL=1
    done < <(grep -nE "[a-zA-Z0-9_.\"'\]\[-]+>=?[0-9]" "$f" 2>/dev/null \
             | grep -v "<" | grep -v "unbounded-ok" \
             | grep -v "requires-python" | grep -v "setuptools" \
             | cut -d: -f2- | sed 's/^ *//' | sort -u)
done <<< "$PIN_FILES"
[ "$PIN_FAIL" -eq 0 ] && pass "全部 Python 依赖有上界（或显式豁免）"

echo ""
echo "── 8/9 .gitignore 密码防线 ──"
hr
if grep -q '^deploy\.env\.server-\*' "$DEPLOY_ROOT/.gitignore" 2>/dev/null; then
    pass ".gitignore 忽略 deploy.env.server-*"
else
    bad ".gitignore 缺少 deploy.env.server-* 通配（明文密码可能入库）"
fi
if git -C "$DEPLOY_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    TRACKED=$(git -C "$DEPLOY_ROOT" ls-files -- 'deploy.env*' ':!deploy.env.example')
    if [ -z "$TRACKED" ]; then
        pass "git 无被跟踪的 deploy.env*（除 example）"
    else
        bad "以下含密文件被 git 跟踪: $TRACKED"
    fi
else
    echo "  [SKIP] 非 git 环境，跳过跟踪检查"
fi

echo ""
echo "── 9/9 通道动词完备性（CHANNEL-CONTRACT §3）──"
hr
# 每个通道文件在干净子 shell 里 source，逐个核对统一动词是否定义。
# 缺动词的通道会在部署时 fail-fast（registry.sh），这里提前到 L1 抓。
VERB_FAIL=0
CHANNEL_VERBS="channel_name channel_supported_kinds channel_wants_host_venv
channel_routing_sync channel_frontend_prepare channel_frontend_preserve
channel_frontend_restore channel_frontend_finalize channel_python_install
channel_python_restart channel_java_install channel_java_restart
channel_service_running channel_service_restart channel_status channel_logs"
for chan in baota native docker; do
    CHAN_FILE="$DEPLOY_ROOT/scripts/channels/${chan}.sh"
    if [ ! -f "$CHAN_FILE" ]; then
        bad "通道文件缺失: scripts/channel/${chan}.sh"
        VERB_FAIL=1
        continue
    fi
    MISSING=$(SCRIPT_DIR="$DEPLOY_ROOT/scripts" SCRIPT_DIR_DEPLOY="$DEPLOY_ROOT/scripts" \
        bash -c '
            source "$1" 2>/dev/null || exit 9
            for v in $2; do declare -F "$v" >/dev/null 2>&1 || echo "$v"; done
        ' _ "$CHAN_FILE" "$CHANNEL_VERBS" 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 9 ]; then
        bad "通道 [$chan] source 失败（依赖缺失？）"
        VERB_FAIL=1
    elif [ -n "$MISSING" ]; then
        bad "通道 [$chan] 缺少统一动词: $(echo "$MISSING" | tr '\n' ' ')"
        VERB_FAIL=1
    else
        pass "通道 [$chan] 动词完备"
    fi
done

echo ""
hr
if [ "$FAIL" -eq 0 ]; then
    echo "  ✅ L1 全部通过（部署链路回归请跑 tests/golden-path-vm.sh）"
    exit 0
else
    echo "  ❌ 失败 $FAIL 项（见上方 [FAIL]）"
    exit 1
fi
