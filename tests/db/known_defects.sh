#!/usr/bin/env bash
# Known defects: builds a fresh database and runs tests/db/known_defects_test.sql.
# Reports each defect as STILL PRESENT or FIXED; it does not fail the build (see docs/test-cases-and-automation.docx §4).
#   PGHOST=/tmp/pg PGPORT=5433 bash tests/db/known_defects.sh
set -euo pipefail
export PGOPTIONS="-c client_min_messages=warning"
cd "$(dirname "$0")/../.."
bash tests/db/build.sh cn_defects >/dev/null
# OBS-36: migrations 010 and 011 say "safe to run twice"; run them again on the fully migrated database
psql -X -q -U postgres -d cn_defects -v ON_ERROR_STOP=1 -f supabase/migrations/010_notifications.sql >/dev/null
psql -X -q -U postgres -d cn_defects -v ON_ERROR_STOP=1 -f supabase/migrations/011_referral_vouchers.sql >/dev/null
psql -X -q -U postgres -d cn_defects -v ON_ERROR_STOP=1 -P pager=off -f tests/db/known_defects_test.sql
