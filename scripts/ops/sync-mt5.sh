#!/bin/bash
# sync-mt5.sh — MT5 五表从 B 全量同步（数据源=B，10 分钟 cron）
# 背景：C↔B 隧道 RTT~220ms，FDW 实时直读不可用（A 是 HK↔HK 低延迟才可行），改定期落地
set -e
export B_PGPASSWORD=root1.0
export L_PGPASSWORD=pamu3fDZH0XpXqbk8KKfmWaB
B_HOST=10.10.0.2
TABLES="fin_mt5_accounts fin_mt5_snapshots fin_mt5_deals fin_mt5_quotes fin_mt5_equity_samples"

L_PSQL() { PGPASSWORD="$L_PGPASSWORD" psql -U root -h localhost -d quant_zc "$@"; }
B_PSQL() { PGPASSWORD="$B_PGPASSWORD" psql -U root -h "$B_HOST" -d quant_zc "$@"; }

L_PSQL -c "TRUNCATE fin_mt5_quotes, fin_mt5_equity_samples, fin_mt5_deals, fin_mt5_snapshots, fin_mt5_accounts CASCADE;" >/dev/null

for t in $TABLES; do
  B_PSQL -c "\copy (SELECT * FROM $t) TO STDOUT" > "/tmp/sync_${t}.csv"
  L_PSQL -c "\copy $t FROM '/tmp/sync_${t}.csv'" >/dev/null
  rm -f "/tmp/sync_${t}.csv"
done

N=$(L_PSQL -Atc "SELECT count(*) FROM fin_mt5_quotes")
echo "$(date '+%F %T') synced ok, quotes=$N"
