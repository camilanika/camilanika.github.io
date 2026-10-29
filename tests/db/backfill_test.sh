#!/usr/bin/env bash
# Migration 014 on a database that already has orders (like the live one):
# existing orders must become MOCK + "needs review", completed ones get an estimated completion date,
# and running the migration a second time must not touch orders created in between.
set -euo pipefail
export PGOPTIONS="-c client_min_messages=warning"
cd "$(dirname "$0")/../.."
DB=cn_backfill
psql -q -U postgres -d postgres -c "drop database if exists $DB" -c "create database $DB" 2>/dev/null
run() { psql -q -X -v ON_ERROR_STOP=1 -U postgres -d "$DB" -f "$1" >/dev/null; }
run tests/db/supabase_stub.sql; run supabase/schema.sql; run supabase/seed.sql
for f in supabase/migrations/*.sql; do [[ "$f" == *014_cashflow.sql ]] && continue; run "$f"; done
q() { psql -X -U postgres -d "$DB" -Atc "$1"; }
q "update inventory set unlimited = true" >/dev/null
q "insert into auth.users (id,email) values ('00000000-0000-0000-0000-00000000000a','a@t'); update profiles set role='admin' where id='00000000-0000-0000-0000-00000000000a'" >/dev/null
mk() { q "select create_order(null, '[{\"variant_id\":1,\"quantity\":1}]', null, 'TES', '0812')->>'order_number'"; }
A=$(mk); B=$(mk)
q "select mark_order_paid('$A','r','credit_card')" >/dev/null
q "select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',false), admin_set_order_status((select id from orders where order_number='$A'),'completed')" >/dev/null
# pretend A was completed and last changed two days ago, B last changed three days ago
q "set session_replication_role = replica; update orders set updated_at = '2026-08-10 15:30+07' where order_number='$A'; update orders set updated_at = '2026-08-09 10:00+07' where order_number='$B'" >/dev/null
run supabase/migrations/014_cashflow.sql
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS  $1"; else echo "FAIL  $1 (got '$2', want '$3')"; fail=1; fi; }
check "existing completed order -> mock, migration, needs review" "$(q "select classification||','||classification_source||','||classification_review from orders where order_number='$A'")" "mock,migration,true"
check "existing pending order -> mock, needs review" "$(q "select classification||','||classification_review from orders where order_number='$B'")" "mock,true"
check "completed order gets an estimated completion date" "$(q "select completed_at is not null and completed_at_estimated from orders where order_number='$A'")" "t"
check "estimated completion date is the order's last change, not the migration time" "$(q "select completed_at = '2026-08-10 15:30+07' from orders where order_number='$A'")" "t"
check "backfill keeps every order's updated_at" "$(q "select count(*) from orders where (order_number='$A' and updated_at = '2026-08-10 15:30+07') or (order_number='$B' and updated_at = '2026-08-09 10:00+07')")" "2"
check "updated_at trigger is back on after the backfill" "$(q "select tgenabled from pg_trigger where tgname='trg_orders_updated'")" "O"
check "pending order has no completion date" "$(q "select completed_at is null from orders where order_number='$B'")" "t"
check "review note explains why" "$(q "select classification_note like '%Sandbox%' from orders where order_number='$A'")" "t"
# after the migration: a new order, then admin marks A as real, then the migration runs again
q "update shop_settings set payments_mode='production'" >/dev/null
C=$(mk)
q "select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',false), cashflow_set_order_classification((select id from orders where order_number='$A'),'real')" >/dev/null
run supabase/migrations/014_cashflow.sql
check "re-running 014 keeps the admin's choice" "$(q "select classification||','||classification_review from orders where order_number='$A'")" "real,false"
check "re-running 014 leaves newer orders alone" "$(q "select classification||','||classification_source from orders where order_number='$C'")" "real,auto"
check "payments_mode survives a re-run" "$(q "select payments_mode from shop_settings")" "production"
check "default categories not duplicated by a re-run" "$(q "select count(*) from expense_categories")" "11"
exit $fail
