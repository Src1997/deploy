#!/usr/bin/env bash
# ============================================================================
# wsl-smoke.sh — WSL Ubuntu L0/L1 冒烟测试（不改生产、不起 systemctl）
#
# Usage:
#   cd /mnt/d/Workspace/deploy   # 或任意含本脚本的 deploy 根
#   bash tests/wsl-smoke.sh
#   bash tests/wsl-smoke.sh --pack    # 额外执行 pack.ps1（需 PowerShell）
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"
SCRIPTS_DIR="$DEPLOY_DIR/scripts"
DO_PACK=false

for arg in "$@"; do
  case "$arg" in
    --pack) DO_PACK=true ;;
    --help|-h)
      echo "Usage: bash tests/wsl-smoke.sh [--pack]"
      exit 0
      ;;
  esac
done

PASS=0
FAIL=0
WARN=0

ok()   { echo -e "\033[32m[PASS]\033[0m $*"; PASS=$((PASS + 1)); }
bad()  { echo -e "\033[31m[FAIL]\033[0m $*"; FAIL=$((FAIL + 1)); }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; WARN=$((WARN + 1)); }
info() { echo -e "\033[36m[INFO]\033[0m $*"; }
hr()   { echo "────────────────────────────────────────────────"; }

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  deploy WSL smoke (L0/L1)"
echo "═══════════════════════════════════════════════════════════"
echo ""
info "DEPLOY_DIR    = $DEPLOY_DIR"
info "WORKSPACE_DIR = $WORKSPACE_DIR"
info "SCRIPTS_DIR   = $SCRIPTS_DIR"
hr

# ── T-L0: bash 语法 ─────────────────────────────────────────────
info "T-L0-01: bash -n on scripts/**/*.sh"
syntax_fail=0
for f in "$SCRIPTS_DIR"/*.sh "$SCRIPTS_DIR"/lib/*.sh "$SCRIPTS_DIR"/ops/*.sh "$SCRIPTS_DIR"/tools/*.sh "$SCRIPT_DIR"/*.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/tmp/deploy-bash-n.err; then
    ok "syntax $(basename "$f")"
  else
    bad "syntax $(basename "$f")"
    cat /tmp/deploy-bash-n.err >&2 || true
    syntax_fail=1
  fi
done
[ "$syntax_fail" -eq 0 ] || true

# ── T-L0: 路径推导（任意工作空间前提）──────────────────────────
info "T-L0-03: path derivation"
if [ -d "$WORKSPACE_DIR" ] && [ -d "$DEPLOY_DIR/scripts" ]; then
  ok "workspace parent of deploy resolves: $WORKSPACE_DIR"
else
  bad "cannot resolve workspace from deploy location"
fi

# pack.ps1 是否通过 config_loader.py 读取 TOML 配置
if grep -qE 'config_loader|load-projects' "$SCRIPTS_DIR/pack.ps1" 2>/dev/null; then
  ok "pack.ps1 uses config_loader.py for TOML configs"
else
  warn "pack.ps1 config_loader pattern not detected (check manually)"
fi

if grep -qE 'D:\\Workspace|D:/Workspace' "$SCRIPTS_DIR/build.ps1" 2>/dev/null; then
  warn "build.ps1 still hardcodes D:\\Workspace"
else
  ok "build.ps1 has no hardcoded D:\\Workspace"
fi

# ── T-L0: 硬编码扫描 ──────────────────────────────────────────
info "T-L0-04/05: hardcoded path / secret scan"
hard_ws=$( { grep -Rne 'D:\\Workspace\|D:/Workspace' "$SCRIPTS_DIR" --include='*.ps1' --include='*.sh' 2>/dev/null || true; } | wc -l | tr -d ' ')
hard_pw=$( { grep -Rne 'root1\.0\|7d7ced854319d1df' "$SCRIPTS_DIR" --include='*.sh' --include='*.ps1' 2>/dev/null || true; } | wc -l | tr -d ' ')
info "hardcoded Workspace hits in scripts/: $hard_ws"
info "hardcoded password hits in scripts/: $hard_pw"
if [ "${hard_ws:-0}" -gt 0 ]; then
  bad "scripts still hardcode D:\\Workspace"
else
  ok "no Workspace hardcodes in scripts/"
fi
if [ "${hard_pw:-0}" -gt 0 ]; then
  bad "scripts still hardcode production passwords (use deploy.env)"
else
  ok "no production password hardcodes in scripts/"
fi
if [ -f "$DEPLOY_DIR/deploy.env.example" ]; then
  if grep -qE 'root1\.0|7d7ced854319d1df' "$DEPLOY_DIR/deploy.env.example" 2>/dev/null; then
    bad "deploy.env.example contains real-looking secrets"
  else
    ok "deploy.env.example has no known production passwords"
  fi
else
  bad "deploy.env.example missing"
fi
if [ -f "$DEPLOY_DIR/configs/financial-api.env.example" ] && [ -f "$DEPLOY_DIR/configs/deepquant.env.example" ]; then
  ok "service .env templates present (financial-api + deepquant)"
else
  bad "missing configs/*.env.example templates"
fi

# ── T-L0: deploy.sh --help ──
info "T-L0-02: deploy.sh --help"
set +e
help_out=$(bash "$SCRIPTS_DIR/deploy.sh" --help 2>&1)
help_rc=$?
set -e
if [ "$help_rc" -eq 0 ] && echo "$help_out" | grep -qiE 'help|用法|Usage|deploy'; then
  ok "deploy.sh --help works"
else
  warn "deploy.sh --help failed (rc=$help_rc)"
  echo "$help_out" | head -5 >&2 || true
fi

# ── T-L0: config_loader.py 验证 ────────────────────────────────
info "T-L0-06: config_loader.py --format check"
if python3 "$SCRIPTS_DIR/lib/config_loader.py" --format check 2>&1; then
  ok "config_loader.py validation passed"
else
  bad "config_loader.py validation failed"
fi

# ── T-L0: _probe-projects.sh 验证 ──────────────────────────────
info "T-L0-07: _probe-projects.sh"
probe_out=$(bash "$SCRIPTS_DIR/lib/_probe-projects.sh" 2>&1 || true)
if echo "$probe_out" | grep -q 'PASS'; then
  ok "_probe-projects.sh passed"
else
  warn "_probe-projects.sh had issues (may need deploy.env)"
  echo "$probe_out" | tail -3 >&2 || true
fi

# ── T-L1: pack 结构（可选执行打包）────────────────────────────
info "T-L1: financial-api package structure"
API_SRC="$WORKSPACE_DIR/financial/financial-api"
if [ ! -d "$API_SRC/app" ]; then
  warn "skip pack checks: backend not found at $API_SRC"
else
  if $DO_PACK; then
    info "running pack.ps1 via PowerShell ..."
    pwsh -NoProfile -File "$SCRIPTS_DIR/pack.ps1" financial-api -DryRun 2>&1 || warn "pack.ps1 -DryRun failed (PowerShell required)"
  fi
  # 优先 dist/packages/（build 正式产出），再回退 dist/
  latest=$(ls -t "$DEPLOY_DIR"/dist/packages/financial-api-*.tar.gz 2>/dev/null | head -1 || true)
  if [ -z "$latest" ]; then
    latest=$(ls -t "$DEPLOY_DIR"/dist/financial-api-*.tar.gz 2>/dev/null | head -1 || true)
  fi
  if [ -z "$latest" ]; then
    warn "no financial-api-*.tar.gz — run: pwsh scripts/pack.ps1 financial-api"
  else
    ok "found archive: $latest"
    # 大包勿整表进变量再 echo（会撞 ARG_MAX）。
    # 注意：pipefail + grep -q 提前退出会使 tar 收到 SIGPIPE 误报失败，故取 PIPESTATUS[grep]。
    tar_has() {
      local pat="$1"
      # grep 写完即退出时 tar 可能 SIGPIPE；只认 grep 的退出码
      tar -tzf "$latest" 2>/dev/null | tr -d '\r' | grep -E "$pat" >/dev/null 2>&1
      local gr="${PIPESTATUS[2]:-1}"
      [ "$gr" -eq 0 ]
    }
    if tar_has '^(\./)?package/'; then
      ok "archive top-level contains package/"
    else
      bad "archive missing package/ prefix"
    fi
    if tar_has '^(\./)?package/VERSION$'; then
      ok "archive contains package/VERSION"
    else
      warn "archive missing package/VERSION (check pack script order bug)"
    fi
    # 部署资产应保留相对路径，禁止拍扁到 package/ 根
    if tar_has '^(\./)?scripts/deploy-financial-api\.sh$'; then
      ok "archive contains scripts/deploy-financial-api.sh (hierarchical)"
    elif tar_has '^(\./)?package/deploy-financial-api\.sh$'; then
      warn "archive has flattened package/deploy-financial-api.sh (legacy)"
    else
      bad "archive missing scripts/deploy-financial-api.sh"
    fi
    if tar_has '^(\./)?configs/systemd/financial-api\.service$'; then
      ok "archive contains configs/systemd/ (hierarchical)"
    elif tar_has 'financial-api\.service$'; then
      warn "systemd unit present but not under configs/systemd/"
    else
      warn "archive missing financial-api.service"
    fi
  fi
fi

hr
echo ""
echo "  Result: PASS=$PASS  FAIL=$FAIL  WARN=$WARN"
echo ""
if [ "$FAIL" -gt 0 ]; then
  echo -e "\033[31m  Smoke finished with failures.\033[0m"
  exit 1
fi
echo -e "\033[32m  Smoke finished (warnings are OK during refactor).\033[0m"
exit 0
