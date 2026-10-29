#!/usr/bin/env bash
# Database tests: builds a fresh database from schema.sql + seed.sql + every migration,
# then runs the cashflow test suite. Needs a local PostgreSQL (16+) reachable with psql.
#   PGHOST=/tmp/pg PGPORT=5433 bash tests/db/run.sh
set -euo pipefail
export PGOPTIONS="-c client_min_messages=warning"
cd "$(dirname "$0")/../.."
bash tests/db/build.sh cn_test >/dev/null
psql -X -q -U postgres -d cn_test -v ON_ERROR_STOP=1 -P pager=off -f tests/db/cashflow_test.sql
