#!/usr/bin/env bash
# Database tests: builds a fresh database from schema.sql + seed.sql + every migration,
# then runs the cashflow test suite. Needs a local PostgreSQL (16+) reachable with psql.
#   PGHOST=/tmp/pg PGPORT=5433 bash tests/db/run.sh
set -euo pipefail
export PGOPTIONS="-c client_min_messages=warning"
cd "$(dirname "$0")/../.."
bash tests/db/build.sh cn_test >/dev/null
psql -X -q -U postgres -d cn_test -v ON_ERROR_STOP=1 -P pager=off -f tests/db/cashflow_test.sql
# security and money invariants (permissions, server-side prices, idempotent payment)
bash tests/db/build.sh cn_test >/dev/null
psql -X -q -U postgres -d cn_test -v ON_ERROR_STOP=1 -P pager=off -f tests/db/security_test.sql
# regression tests for the defects fixed by migration 017 (QA fixes, 8 Nov 2026)
bash tests/db/build.sh cn_test >/dev/null
# OBS-7: re-running 014 on its own after 016/017 must refuse and change nothing, even without ON_ERROR_STOP
rerun=$(psql -X -q -U postgres -d cn_test -f supabase/migrations/014_cashflow.sql 2>&1 || true)
if [[ "$rerun" == *"Migration 016 is already applied"* ]]; then
  echo "PASS   | OBS-7 migration 014 refuses to run again on its own"
else
  echo "FAIL   | OBS-7 migration 014 did not refuse to run again on its own"; exit 1
fi
psql -X -q -U postgres -d cn_test -v ON_ERROR_STOP=1 -P pager=off -f tests/db/qa_fixes_test.sql
