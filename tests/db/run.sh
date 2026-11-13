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
# OBS-36: re-running 010 or 011 after 017 must refuse and change nothing (qa_fixes_test.sql below then checks
# OBS-2, 8, 15 and 17 on this same database)
for m in 010_notifications 011_referral_vouchers; do
  rerun=$(psql -X -q -U postgres -d cn_test -f "supabase/migrations/$m.sql" 2>&1 || true)
  if [[ "$rerun" == *"Migration 017 is already applied"* ]]; then
    echo "PASS   | OBS-36 migration ${m%%_*} refuses to run again after 017"
  else
    echo "FAIL   | OBS-36 migration ${m%%_*} did not refuse to run again after 017"; exit 1
  fi
done
psql -X -q -U postgres -d cn_test -v ON_ERROR_STOP=1 -P pager=off -f tests/db/qa_fixes_test.sql
# regression tests for migrations 018/019 (OBS-12 order privacy, DEF-002 checkout guard); both must be safe to run twice
bash tests/db/build.sh cn_test >/dev/null
psql -X -q -U postgres -d cn_test -v ON_ERROR_STOP=1 -f supabase/migrations/018_order_privacy_checkout_guard.sql >/dev/null
psql -X -q -U postgres -d cn_test -v ON_ERROR_STOP=1 -f supabase/migrations/019_order_columns_private.sql >/dev/null
echo "PASS   | migrations 018 and 019 run twice without errors"
psql -X -q -U postgres -d cn_test -v ON_ERROR_STOP=1 -P pager=off -f tests/db/fixes_018_test.sql
# halfway through the upgrade (018 run, 019 not yet): the admin page that is live now still reads orders directly
UNTIL=018 bash tests/db/build.sh cn_test >/dev/null
mid=$(psql -X -q -At -U postgres -d cn_test -v ON_ERROR_STOP=1 -c "insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000a', 'admin@test.local'); update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-00000000000a';" -c "begin; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true); set local role authenticated; select count(classification_note) >= 0 and jsonb_typeof(public.admin_list_orders()) = 'array' from public.orders; commit;" 2>&1 | grep -E '^(t|f)$|ERROR' || true)
if [[ "$mid" == "t" ]]; then echo "PASS   | after 018 alone, the old admin page's select(\"*\") and admin_list_orders both work"
else echo "FAIL   | after 018 alone the live admin page would break: $mid"; exit 1; fi
# loyalty programme (migrations 012, 013): milestones, repeats, refunds, recurring tiers, ongkir, permissions
bash tests/db/build.sh cn_test >/dev/null
psql -X -q -U postgres -d cn_test -v ON_ERROR_STOP=1 -P pager=off -f tests/db/loyalty_test.sql
# voucher policy (OBS-39, QA run INSP-5): the database keeps a used voucher when a paid order is cancelled, and
# refund.html says so (it used to promise the voucher back)
if grep -q "tidak dikembalikan, termasuk jika pesanan itu dibatalkan" refund.html; then
  echo "PASS   | OBS-39 refund.html says a voucher used on a paid order is not returned"
else
  echo "FAIL   | OBS-39 refund.html no longer says what the database does with vouchers of cancelled orders"; exit 1
fi
bash tests/db/build.sh cn_test >/dev/null
psql -X -q -U postgres -d cn_test -v ON_ERROR_STOP=1 -P pager=off -f tests/db/voucher_policy_test.sql
# Paket Hemat, Testimoni pelanggan and the storefront call (migration 020)
bash tests/db/build.sh cn_test >/dev/null
psql -X -q -U postgres -d cn_test -v ON_ERROR_STOP=1 -P pager=off -f tests/db/paket_testimoni_test.sql
# series only, series texts, Semua texts, gallery, no GoFood (migration 021)
bash tests/db/build.sh cn_test >/dev/null
psql -X -q -U postgres -d cn_test -v ON_ERROR_STOP=1 -P pager=off -f tests/db/series_gallery_test.sql
# opening days in the shop schedule (migration 022)
bash tests/db/build.sh cn_test >/dev/null
psql -X -q -U postgres -d cn_test -v ON_ERROR_STOP=1 -P pager=off -f tests/db/shop_days_test.sql
