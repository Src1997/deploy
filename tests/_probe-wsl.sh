#!/usr/bin/env bash
set -euo pipefail
# Load nvm node if present
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

echo "=== OS ==="
uname -a
echo "=== cmds ==="
for c in bash tar gzip curl python3 pip3 git node pnpm npm flock ss redis-cli psql nginx envsubst dos2unix; do
  printf "%-14s " "$c"
  if command -v "$c" >/dev/null 2>&1; then
    echo "OK $($c --version 2>&1 | head -1 | cut -c1-50)"
  else
    echo MISSING
  fi
done
echo "=== python3 -m venv ==="
if python3 -m venv --help >/dev/null 2>&1; then echo OK; else echo MISSING; fi
echo "=== apt ==="
dpkg -l curl tar gzip python3 python3-venv git util-linux gettext-base 2>/dev/null | awk '/^ii/{print $2,$3}' || true
echo "=== done ==="
