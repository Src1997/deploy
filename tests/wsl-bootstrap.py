#!/usr/bin/env python3
"""Fix LF, ensure WSL apt deps + nvm node on PATH for probe."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def fix_lf() -> None:
    for folder in ("tests", "scripts"):
        for p in (ROOT / folder).glob("*.sh"):
            raw = p.read_bytes()
            fixed = raw.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
            if fixed != raw:
                p.write_bytes(fixed)
                print(f"LF fixed: {p.relative_to(ROOT)}")


def run(cmd: list[str]) -> int:
    print("+", " ".join(cmd))
    return subprocess.call(cmd, cwd=str(ROOT))


def main() -> int:
    fix_lf()
    pkgs = [
        "curl", "tar", "gzip", "python3", "python3-venv", "python3-pip", "git",
        "util-linux", "coreutils", "findutils", "grep", "gawk",
        "gettext-base", "ca-certificates", "unzip", "dos2unix",
    ]
    run(["sudo", "apt-get", "update", "-qq"])
    run(["sudo", "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", "-qq", *pkgs])

    # Ensure nvm node is installed (user already has v24)
    nvm_check = """
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
if ! command -v node >/dev/null; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  . "$HOME/.nvm/nvm.sh"
  nvm install --lts
fi
node -v
npm -v
# enable corepack pnpm if needed
corepack enable >/dev/null 2>&1 || true
command -v pnpm >/dev/null || npm install -g pnpm@latest
pnpm -v || true
"""
    run(["bash", "-lc", nvm_check])

    with open(ROOT / "tests" / "_probe-out.txt", "w", encoding="utf-8") as f:
        subprocess.run(["bash", "tests/_probe-wsl.sh"], cwd=str(ROOT), stdout=f, stderr=subprocess.STDOUT)
    print((ROOT / "tests" / "_probe-out.txt").read_text(encoding="utf-8", errors="replace"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
