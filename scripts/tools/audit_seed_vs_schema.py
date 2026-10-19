#!/usr/bin/env python
"""audit_seed_vs_schema.py — 审计「数据库表列」与「seed 源码」的覆盖缺口。

背景：batch3 重构把 meta JSONB 拆成独立列后，seed fixture 没跟上
（fin_navigation_nodes.required_capability 全 NULL → allowedMenuIds=[] → 菜单全隐）。
本脚本系统性找出同类缺口：运营库中「有非空数据、但 seed 源码从未提及」的列。

用法（本地，需 ssh 别名与受管 python）：
  python audit_seed_vs_schema.py --host-alias serverB --pg-user root \
      --pg-pass 'xxx' --db quant_zc --seed-dir D:/Workspace/financial/financial-api/app

判定逻辑（保守，宁可漏报不误报）：
  - 列名 snake_case 或其 camelCase 变体出现在 seed 源码文本中 → 视为已覆盖
  - 排除审计噪音列：id/created_at/updated_at/deleted_at/description 等
  - 候选列在源站逐列查非空行数，非空行数 > 0 才报告
"""
import argparse
import subprocess
import sys
from pathlib import Path

NOISE_COLS = {
    "id", "created_at", "updated_at", "deleted_at", "password", "password_hash",
    "description", "sort_order", "nav_sort_order", "config_value", "value_type",
}


def ssh_psql(alias: str, pg_user: str, pg_pass: str, db: str, sql: str) -> str:
    cmd = [
        "ssh", "-o", "ConnectTimeout=20", alias,
        "PGPASSWORD='%s' psql -U '%s' -h localhost -d '%s' -Atc \"%s\""
        % (pg_pass, pg_user, db, sql.replace('"', '\\"')),
    ]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    return r.stdout.strip()


def camel(snake: str) -> str:
    parts = snake.split("_")
    return parts[0] + "".join(p.title() for p in parts[1:])


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host-alias", required=True)
    ap.add_argument("--pg-user", required=True)
    ap.add_argument("--pg-pass", required=True)
    ap.add_argument("--db", default="quant_zc")
    ap.add_argument("--seed-dir", required=True)
    args = ap.parse_args()

    seed_dir = Path(args.seed_dir)
    seed_text = "\n".join(
        p.read_text(encoding="utf-8", errors="replace")
        for p in seed_dir.rglob("*.py")
    )
    print("seed 源码: %d 个文件 / %d 字符" % (
        len(list(seed_dir.rglob('*.py'))), len(seed_text)))

    # 1. 全部表
    tables = ssh_psql(
        args.host_alias, args.pg_user, args.pg_pass, args.db,
        "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename",
    ).splitlines()
    print("表总数: %d" % len(tables))

    gaps = []
    for t in tables:
        if t.startswith(("bak", "_alembic")):
            continue
        # 2. 表的列 + 该表行数
        cols_raw = ssh_psql(
            args.host_alias, args.pg_user, args.pg_pass, args.db,
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_name='%s' AND table_schema='public' ORDER BY ordinal_position" % t,
        ).splitlines()
        rows = ssh_psql(
            args.host_alias, args.pg_user, args.pg_pass, args.db,
            "SELECT count(*) FROM %s" % t,
        )
        try:
            n_rows = int(rows)
        except ValueError:
            continue
        if n_rows == 0:
            continue

        for col in cols_raw:
            if col in NOISE_COLS:
                continue
            # 3. seed 源码是否提及（snake 或 camel）
            if col in seed_text or camel(col) in seed_text:
                continue
            # 4. 源站该列是否有非空数据
            nn = ssh_psql(
                args.host_alias, args.pg_user, args.pg_pass, args.db,
                "SELECT count(*) FROM %s WHERE %s IS NOT NULL" % (t, col),
            )
            try:
                n_nn = int(nn)
            except ValueError:
                continue
            if n_nn > 0:
                gaps.append((t, col, n_nn, n_rows))

    print()
    if not gaps:
        print("✅ 未发现缺口：所有运营数据的列均被 seed 源码覆盖")
        return
    print("⚠️ 发现 %d 个缺口（源站有数据、seed 源码未提及该列）：" % len(gaps))
    print("%-32s %-28s %8s %8s" % ("表", "列", "非空行", "总行"))
    for t, col, n_nn, n_rows in gaps:
        print("%-32s %-28s %8d %8d" % (t, col, n_nn, n_rows))


if __name__ == "__main__":
    sys.exit(main())
