#!/usr/bin/env bash
# Bootstrap WSL Ubuntu deps for deploy tooling + run probe
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tests/fix-lf.py || true

echo "==> apt update + install base tools"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  curl tar gzip python3 python3-venv python3-pip git \
  util-linux coreutils findutils grep gawk \
  gettext-base ca-certificates unzip \
  > /tmp/deploy-apt.log 2>&1 || {
    echo "apt failed, see /tmp/deploy-apt.log"
    tail -40 /tmp/deploy-apt.log
    exit 1
  }

# optional niceties
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dos2unix 2>/dev/null || true

echo "==> probe"
bash tests/_probe-wsl.sh | tee tests/_probe-out.txt

echo "==> bootstrap done"
