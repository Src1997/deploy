#!/usr/bin/env python3
"""Convert deploy shell scripts to LF line endings for WSL."""
from pathlib import Path

root = Path(__file__).resolve().parent
scripts = root.parent / "scripts"
paths = list(root.glob("*.sh")) + list(scripts.glob("*.sh")) + list((scripts / "lib").glob("*.sh"))
for p in paths:
    raw = p.read_bytes()
    fixed = raw.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    if fixed != raw:
        p.write_bytes(fixed)
        print(f"LF fixed: {p}")
    else:
        print(f"already LF: {p}")
