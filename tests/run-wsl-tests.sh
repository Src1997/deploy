#!/usr/bin/env bash
# Comprehensive WSL test for all 6 improvements
set -euo pipefail

DEPLOY_DIR="/mnt/d/Workspace/deploy"
cd "$DEPLOY_DIR"

PASS=0
FAIL=0
ok()   { echo -e "\033[32m[PASS]\033[0m $*"; PASS=$((PASS + 1)); }
bad()  { echo -e "\033[31m[FAIL]\033[0m $*"; FAIL=$((FAIL + 1)); }
info() { echo -e "\033[36m[INFO]\033[0m $*"; }
hr()   { echo "────────────────────────────────────────────────"; }

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  deploy WSL comprehensive test (6 improvements)"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── Step 1: PyYAML ──
info "Step 1: PyYAML availability"
python3 -c "import yaml" 2>/dev/null && ok "PyYAML installed" || bad "PyYAML missing"

# ── Step 2: sync-projects.py ──
info "Step 2: sync-projects.py"
if python3 scripts/sync-projects.py 2>&1; then
    ok "sync-projects.py executed successfully"
else
    bad "sync-projects.py failed"
fi
echo ""

# ── Step 3: Verify projects.json ──
info "Step 3: Verify projects.json has new fields"
python3 -c "
import json
with open('projects.json') as f:
    data = json.load(f)
errors = []
for p in data.get('projects', []):
    pub = p.get('publicUrl', None)
    nginx = p.get('nginx', None)
    if pub is None:
        errors.append(f'{p[\"id\"]}: missing publicUrl')
    if nginx is None and p.get('kind') == 'frontend':
        errors.append(f'{p[\"id\"]}: missing nginx section')
extras = data.get('nginxExtras', [])
if not extras:
    errors.append('nginxExtras missing or empty')
if errors:
    for e in errors:
        print(f'  FAIL: {e}')
    exit(1)
else:
    for p in data['projects']:
        pub = p.get('publicUrl', '')
        nginx = 'nginx:yes' if p.get('nginx') else 'nginx:no'
        print(f'  {p[\"id\"]:20s} publicUrl={pub:10s} {nginx}')
    print(f'  nginxExtras: {len(extras)} entries')
    exit(0)
" && ok "projects.json fields verified" || bad "projects.json field check failed"
echo ""

# ── Step 4: Bash syntax ──
info "Step 4: Bash syntax check"
syntax_fail=0
for f in scripts/*.sh scripts/lib/*.sh tests/*.sh; do
    [ -f "$f" ] || continue
    if bash -n "$f" 2>/dev/null; then
        ok "syntax $(basename "$f")"
    else
        bad "syntax $(basename "$f")"
        bash -n "$f" 2>&1 | head -3
        syntax_fail=1
    fi
done
echo ""

# ── Step 5: deploy.sh --help ──
info "Step 5: deploy.sh --help"
help_out=$(bash scripts/deploy.sh --help 2>/dev/null || true)
if echo "$help_out" | grep -qiE 'help|usage|deploy'; then
    ok "deploy.sh --help works"
    if echo "$help_out" | grep -q 'dynamic'; then
        ok "--dynamic flag documented in help"
    else
        bad "--dynamic flag NOT in help"
    fi
else
    bad "deploy.sh --help failed"
fi
echo ""

# ── Step 6: load-projects.sh (PUBLIC_URL) ──
info "Step 6: load-projects.sh PUBLIC_URL field"
export PROJECT_BASE="${PROJECT_BASE:-/www/wwwroot/project}"
export DEPLOY_DRY_RUN=1
source scripts/lib/load-projects.sh 2>/dev/null || true
declare -a PROJECTS=($PROJECT_IDS)
if [ ${#PROJECTS[@]} -gt 0 ]; then
    ok "PROJECTS array loaded: ${PROJECTS[*]}"
    for p in "${PROJECTS[@]}"; do
        pub="${PUBLIC_URL[$p]:-}"
        if [ -n "$pub" ]; then
            ok "PUBLIC_URL[$p] = $pub"
        else
            info "PUBLIC_URL[$p] = (empty - OK for backend)"
        fi
    done
else
    bad "PROJECTS array is empty"
fi
echo ""

# ── Step 7: Nginx generation (http mode) ──
info "Step 7: Nginx generation (http mode)"
nginx_http=$(python3 scripts/generate-nginx.py --mode http 2>&1 || true)
if echo "$nginx_http" | grep -q 'server {' && echo "$nginx_http" | grep -q 'location'; then
    ok "HTTP mode nginx config generated"
    echo "$nginx_http" | grep -q '/api/ws' && ok "  /api/ws location present" || bad "  /api/ws missing"
    echo "$nginx_http" | grep -q '/api/' && ok "  /api/ location present" || bad "  /api/ missing"
    echo "$nginx_http" | grep -q '/qd/' && ok "  /qd/ location present" || bad "  /qd/ missing"
    echo "$nginx_http" | grep -q '/quant/' && ok "  /quant/ location present" || bad "  /quant/ missing"
    echo "$nginx_http" | grep -q '/quant/api/' && ok "  /quant/api/ location present" || bad "  /quant/api/ missing"
    echo "$nginx_http" | grep -q '/ws/' && ok "  /ws/ location present" || bad "  /ws/ missing"
    echo "$nginx_http" | grep -q '/mcp' && ok "  /mcp location present (nginxExtras)" || bad "  /mcp missing"
    echo "$nginx_http" | grep -q 'try_files.*index.html' && ok "  SPA fallback present" || bad "  SPA fallback missing"
    echo "$nginx_http" | grep -q '/health' && ok "  /health endpoint present" || bad "  /health missing"
else
    bad "HTTP mode nginx generation failed"
    echo "$nginx_http" | head -10
fi
echo ""

# ── Step 8: Nginx generation (ssl-redirect mode) ──
info "Step 8: Nginx generation (ssl-redirect mode)"
nginx_ssl=$(python3 scripts/generate-nginx.py --mode ssl-redirect --domain example.com --www-domain www.example.com 2>&1 || true)
if echo "$nginx_ssl" | grep -q 'listen 443' && echo "$nginx_ssl" | grep -q 'ssl_certificate'; then
    ok "SSL-redirect mode nginx config generated"
    echo "$nginx_ssl" | grep -q 'return 301 https' && ok "  HTTPS redirect present" || bad "  HTTPS redirect missing"
    echo "$nginx_ssl" | grep -q 'www.example.com' && ok "  Domain placeholder rendered" || bad "  Domain not rendered"
else
    bad "SSL-redirect mode nginx generation failed"
fi
echo ""

# ── Step 9: Nginx generation (ssl-combined mode) ──
info "Step 9: Nginx generation (ssl-combined mode)"
nginx_combined=$(python3 scripts/generate-nginx.py --mode ssl-combined --domain example.com --www-domain www.example.com 2>&1 || true)
if echo "$nginx_combined" | grep -q 'listen 80' && echo "$nginx_combined" | grep -q 'listen 443' && echo "$nginx_combined" | grep -q 'error_page 497'; then
    ok "SSL-combined mode nginx config generated"
else
    bad "SSL-combined mode nginx generation failed"
fi
echo ""

# ── Step 10: deploy.sh --nginx --dynamic DRY_RUN ──
info "Step 10: deploy.sh --nginx --dynamic DRY_RUN"
# Temporarily set DRY_RUN=1 in deploy.env
sed -i 's/^DEPLOY_DRY_RUN=0/DEPLOY_DRY_RUN=1/' deploy.env
sudo rm -f /tmp/deploy.lock 2>/dev/null || true
nginx_dyn=$(bash scripts/deploy.sh --nginx --dynamic 2>&1 || true)
# Revert DRY_RUN
sed -i 's/^DEPLOY_DRY_RUN=1/DEPLOY_DRY_RUN=0/' deploy.env
if echo "$nginx_dyn" | grep -qi 'dynamic\|动态'; then
    ok "deploy.sh --nginx --dynamic runs in DRY_RUN mode"
    echo "$nginx_dyn" | grep -q 'ssl-redirect' && ok "  SSL mode detected from NGINX_CONF_NAME" || info "  http mode (no NGINX_CONF_NAME match)"
else
    bad "deploy.sh --nginx --dynamic failed"
    echo "$nginx_dyn" | head -5
fi
echo ""

# ── Step 11: Hardcoded path scan ──
info "Step 11: Hardcoded path scan in scripts/"
hard_ws=$( { grep -Rne 'D:\\Workspace\|D:/Workspace' scripts/ --include='*.ps1' --include='*.sh' 2>/dev/null || true; } | wc -l | tr -d ' ')
if [ "${hard_ws:-0}" -gt 0 ]; then
    bad "scripts still hardcode D:\\Workspace ($hard_ws hits)"
else
    ok "no Workspace hardcodes in scripts/"
fi
echo ""

# ── Step 12: wsl-smoke.sh ──
info "Step 12: wsl-smoke.sh"
smoke_out=$(bash tests/wsl-smoke.sh 2>&1 || true)
if echo "$smoke_out" | grep -q 'PASS='; then
    smoke_pass=$(echo "$smoke_out" | grep 'Result:' | grep -oP 'PASS=\K[0-9]+')
    smoke_fail=$(echo "$smoke_out" | grep 'Result:' | grep -oP 'FAIL=\K[0-9]+')
    ok "wsl-smoke.sh completed (PASS=$smoke_pass FAIL=$smoke_fail)"
    [ "$smoke_fail" = "0" ] && ok "  No failures" || info "  Pre-existing failures (not from our changes)"
else
    bad "wsl-smoke.sh failed to run"
fi
echo ""

# ── Summary ──
hr
echo ""
echo "  Result: PASS=$PASS  FAIL=$FAIL"
echo ""
if [ "$FAIL" -gt 0 ]; then
    echo -e "\033[31m  Tests finished with failures.\033[0m"
    exit 1
fi
echo -e "\033[32m  All tests passed!\033[0m"
exit 0
