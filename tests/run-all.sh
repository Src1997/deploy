#!/usr/bin/env bash
# ================================================================
# tests/run-all.sh — 本地一键回归（无需服务器）
#
# 覆盖：
#   1. 全部 shell 脚本 bash -n 语法校验
#   2. config_loader --format check（TOML 解析 + manifest 校验）
#   3. servers 清单非空（env 单源化后的关键回归点）
#   4. bash-eval 输出冒烟（PROJECT_IDS 非空，load-projects.sh 依赖）
#   5. .gitignore 密码防线（deploy.env* 必须被忽略）
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
echo "║  deploy 工具箱一键回归（$DEPLOY_ROOT）"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "── 1/5 bash -n 语法校验 ──"
hr
SYNTAX_FAIL=0
for s in "$DEPLOY_ROOT"/scripts/*.sh \
         "$DEPLOY_ROOT"/scripts/lib/*.sh \
         "$DEPLOY_ROOT"/scripts/ops/*.sh \
         "$DEPLOY_ROOT"/scripts/tools/*.sh; do
    [ -f "$s" ] || continue
    if ! ERR=$(bash -n "$s" 2>&1); then
        bad "语法: ${s#$DEPLOY_ROOT/}"
        echo "$ERR" | sed 's/^/         /'
        SYNTAX_FAIL=1
    fi
done
[ "$SYNTAX_FAIL" -eq 0 ] && pass "全部 shell 脚本语法通过"

echo ""
echo "── 2/5 config_loader 校验 ──"
hr
CHECK_OUT=$(cd "$DEPLOY_ROOT/scripts/lib" && "$PY" config_loader.py --format check 2>&1)
CHECK_RC=$?
if [ "$CHECK_RC" -eq 0 ]; then
    pass "config_loader check: $(echo "$CHECK_OUT" | head -1)"
else
    bad "config_loader check（退出码 $CHECK_RC）"
    echo "$CHECK_OUT" | sed 's/^/         /'
fi

echo ""
echo "── 3/5 servers 清单（env 单源化回归点）──"
hr
SERVERS_JSON=$(cd "$DEPLOY_ROOT/scripts/lib" && "$PY" config_loader.py 2>/dev/null \
    | "$PY" -c "import json,sys; m=json.load(sys.stdin); print(' '.join(m['servers'].keys()))")
if [ -n "$SERVERS_JSON" ]; then
    pass "servers 非空: $SERVERS_JSON"
else
    bad "servers 清单为空（deploy.env.server-* 的 DOMAIN 都没读到？）"
fi

echo ""
echo "── 4/5 bash-eval 冒烟（load-projects.sh 依赖）──"
hr
BASH_EVAL_OUT=$(cd "$DEPLOY_ROOT/scripts/lib" && "$PY" config_loader.py --format bash-eval 2>/dev/null)
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
echo "── 5/5 .gitignore 密码防线 ──"
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
    warn_skip=1  # 非 git 环境跳过
    echo "  [SKIP] 非 git 环境，跳过跟踪检查"
fi

echo ""
hr
if [ "$FAIL" -eq 0 ]; then
    echo "  ✅ 全部通过"
    exit 0
else
    echo "  ❌ 失败 $FAIL 项（见上方 [FAIL]）"
    exit 1
fi
