#!/bin/bash
set -e

echo "=== PostgreSQL setup ==="
PG_PORT=$(pg_isready 2>/dev/null | grep -oP ':\K[0-9]+' || echo "5432")
echo "PG running on port: $PG_PORT"

# Create root user with password
sudo -u postgres psql -p "$PG_PORT" <<'SQL'
DO $$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'root') THEN
      CREATE USER root WITH PASSWORD 'root1.0' SUPERUSER;
   ELSE
      ALTER USER root WITH PASSWORD 'root1.0' SUPERUSER;
   END IF;
END
$$;

-- Create databases if not exist
SELECT 'CREATE DATABASE quant_zc OWNER root'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'quant_zc')\gexec

SELECT 'CREATE DATABASE quantdinger OWNER root'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'quantdinger')\gexec

\l
SQL

echo "=== Verify root user can connect ==="
PGPASSWORD=root1.0 psql -h localhost -p "$PG_PORT" -U root -d quant_zc -c "SELECT 1 as test;" 2>&1 || echo "Connection failed (expected if pg_hba.conf requires adjustment)"

echo "=== Redis verify ==="
redis-cli ping

echo "=== All services ready ==="
