#!/usr/bin/env bash
# Builds a fresh test database from the repo's SQL, in the same order as SHOP_SETUP.md.
# Usage: PGHOST=/tmp/pg PGPORT=5433 tests/db/build.sh <dbname>
set -euo pipefail
export PGOPTIONS="-c client_min_messages=warning"
cd "$(dirname "$0")/../.."
DB="${1:-cn_test}"
psql -q -U postgres -d postgres -c "drop database if exists $DB" -c "create database $DB"
run() { psql -q -X -v ON_ERROR_STOP=1 -U postgres -d "$DB" -f "$1" >/dev/null 2>"/tmp/cn_build_err" || { echo "FAILED: $1"; cat /tmp/cn_build_err; exit 1; }; }
run tests/db/supabase_stub.sql
run supabase/schema.sql
run supabase/seed.sql
for f in supabase/migrations/*.sql; do run "$f"; done
echo "built $DB"
