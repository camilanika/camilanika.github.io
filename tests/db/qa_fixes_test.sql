-- =====================================================================
-- QA fixes: regression tests for the defects fixed by migration 017 (QA inspection, 8 Nov 2026)
-- Run with tests/db/run.sh, which builds a fresh database from the repo, then runs this file.
-- These checks started as executable bug reports in known_defects_test.sql; each one now has to pass.
-- IDs match §4 of docs/test-cases-and-automation.docx. The script fails if any check fails.
-- =====================================================================
\set ON_ERROR_STOP 1
set client_min_messages = warning;
\o /dev/null

create schema t;
create table t.results (n serial primary key, id text not null, name text not null, ok boolean not null, info text);
grant usage on schema t to anon, authenticated;
grant all on all tables in schema t to anon, authenticated;
grant all on all sequences in schema t to anon, authenticated;
create function t.ok(id text, c boolean, name text, info text default null) returns void language sql as $$
  insert into t.results (id, name, ok, info) values (id, name, coalesce(c, false), info) $$;
grant execute on all functions in schema t to anon, authenticated;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@test.local'),
  ('00000000-0000-0000-0000-00000000000c', 'customer@test.local'),
  ('00000000-0000-0000-0000-0000000000b1', 'buyer@test.local'),
  ('00000000-0000-0000-0000-0000000000d1', 'leaving@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-00000000000a';
update public.inventory set unlimited = true;
create function t.num(o jsonb) returns text language sql as $$ select o->>'order_number' $$;

-- ---------------------------------------------------------------- DEF-002: one order can hold far more than the per-line cap
do $$ begin
  perform public.create_order(null, '[{"variant_id":2,"quantity":100},{"variant_id":2,"quantity":100},{"variant_id":2,"quantity":100},{"variant_id":2,"quantity":100},{"variant_id":2,"quantity":100}]', null, 'Bulk', '081234567890');
  perform t.ok('DEF-002', false, 'one order cannot hold more than 100 of the same item by splitting it over lines', 'order for 5 x 100 of variant 2 accepted');
exception when others then perform t.ok('DEF-002', true, 'one order cannot hold more than 100 of the same item by splitting it over lines', sqlerrm);
end $$;

-- ---------------------------------------------------------------- OBS-1: promo usage limit
insert into public.promotions (name, code, discount_type, value, usage_limit, announce) values ('QA once', 'QAONCE', 'fixed', 5000, 1, false);
do $$ declare o1 jsonb; o2 jsonb; d2 int; begin
  o1 := public.create_order(null, '[{"variant_id":1,"quantity":2}]', 'QAONCE', 'A', '081234567890');
  begin
    o2 := public.create_order(null, '[{"variant_id":1,"quantity":2}]', 'QAONCE', 'B', '081234567891');
    d2 := (select discount from public.orders where order_number = t.num(o2));
    perform t.ok('OBS-1', d2 = 0, 'a promo with usage_limit 1 discounts only one order', 'second order discount ' || d2);
  exception when others then perform t.ok('OBS-1', true, 'a promo with usage_limit 1 discounts only one order', sqlerrm); end;
end $$;

-- ---------------------------------------------------------------- OBS-2: single-use voucher and late payments
insert into public.vouchers (code, source, user_id, discount_type, value, assigned_at)
  values ('CN-QA01-VCHR', 'admin', '00000000-0000-0000-0000-0000000000b1', 'fixed', 10000, now()),
         ('CN-QA02-VCHR', 'admin', '00000000-0000-0000-0000-0000000000b1', 'fixed', 10000, now());
do $$ declare a jsonb; begin
  -- A's payment page may still be open for 15 minutes after expiry: the voucher stays with A
  a := public.create_order('00000000-0000-0000-0000-0000000000b1', '[{"variant_id":2,"quantity":1}]', 'CN-QA01-VCHR', 'U1', '081234567892');
  update public.orders set expires_at = now() - interval '1 minute' where order_number = t.num(a);
  begin
    perform public.create_order('00000000-0000-0000-0000-0000000000b1', '[{"variant_id":2,"quantity":1}]', 'CN-QA01-VCHR', 'U1', '081234567892');
    perform t.ok('OBS-2', false, 'within the grace period a second order can''t take the voucher', 'second order got it');
  exception when others then perform t.ok('OBS-2', sqlerrm like '%VOUCHER_RESERVED%', 'within the grace period a second order can''t take the voucher', sqlerrm); end;
end $$;
do $$ declare a jsonb; b jsonb; begin
  -- after the grace period B may take it; if A's payment still arrives, A is flagged for the admin
  a := public.create_order('00000000-0000-0000-0000-0000000000b1', '[{"variant_id":2,"quantity":1}]', 'CN-QA02-VCHR', 'U1', '081234567892');
  update public.orders set expires_at = now() - interval '20 minutes' where order_number = t.num(a);
  b := public.create_order('00000000-0000-0000-0000-0000000000b1', '[{"variant_id":2,"quantity":1}]', 'CN-QA02-VCHR', 'U1', '081234567892');
  perform public.mark_order_paid(t.num(b), 'trx-b', 'va');
  perform public.mark_order_paid(t.num(a), 'trx-a', 'va');
  perform t.ok('OBS-2', (select payment_issue from public.orders where order_number = t.num(a)) like '%VOUCHER_CONFLICT%',
               'a late payment whose voucher went to another order is flagged for the admin',
               'payment_issue ' || coalesce((select payment_issue from public.orders where order_number = t.num(a)), 'NULL'));
  perform t.ok('OBS-2', (select status from public.vouchers where code = 'CN-QA02-VCHR') = 'used' and
               (select used_order_id from public.vouchers where code = 'CN-QA02-VCHR') = (select id from public.orders where order_number = t.num(b)),
               'the voucher is used once, by the order that held it', null);
end $$;

-- ---------------------------------------------------------------- OBS-4: late payment of an expired order oversells silently
update public.inventory set unlimited = false, stock = 2, reserved = 0 where variant_id = 3;
do $$ declare a jsonb; b jsonb; s int; begin
  a := public.create_order(null, '[{"variant_id":3,"quantity":2}]', null, 'A', '081234567890');
  update public.orders set expires_at = now() - interval '20 minutes' where order_number = t.num(a);
  perform public.release_expired_orders();
  b := public.create_order(null, '[{"variant_id":3,"quantity":2}]', null, 'B', '081234567891');
  perform public.mark_order_paid(t.num(b), 'trx-b', 'qris');
  perform public.mark_order_paid(t.num(a), 'trx-a', 'qris');   -- A's payment arrives late
  s := (select coalesce(sum(change), 0) from public.stock_movements where variant_id = 3 and reason = 'sale');
  perform t.ok('OBS-4', s = -2, 'stock ledger matches the real stock change (2 -> 0) when an expired order is paid late', 'sale movements total ' || s);
  perform t.ok('OBS-4', (select payment_issue from public.orders where order_number = t.num(a)) like 'OVERSOLD:3:2%', 'the oversold late payment is flagged for the admin',
               'payment_issue ' || coalesce((select payment_issue from public.orders where order_number = t.num(a)), 'NULL'));
exception when others then perform t.ok('OBS-4', false, 'stock ledger matches the real stock change when an expired order is paid late', 'setup error: ' || sqlerrm);
end $$;

-- ---------------------------------------------------------------- OBS-22: releasing an order frees stock it never held
update public.inventory set unlimited = true, stock = 0, reserved = 0 where variant_id = 4;
do $$ declare x jsonb; r int; begin
  x := public.create_order(null, '[{"variant_id":4,"quantity":3}]', null, 'X', '081234567890');   -- unlimited: nothing reserved
  update public.inventory set unlimited = false, stock = 3 where variant_id = 4;                    -- admin switches to counted stock
  perform public.create_order(null, '[{"variant_id":4,"quantity":3}]', null, 'Y', '081234567891'); -- Y holds all 3
  perform public.release_order(t.num(x), 'expired');
  r := (select reserved from public.inventory where variant_id = 4);
  perform t.ok('OBS-22', r = 3, 'expiring an order that reserved nothing keeps the other order''s hold', 'reserved after release ' || r || ' (want 3)');
exception when others then perform t.ok('OBS-22', false, 'expiring an order that reserved nothing keeps the other order''s hold', 'setup error: ' || sqlerrm);
end $$;

-- ---------------------------------------------------------------- OBS-14: negative delivery fee tier
update public.shop_settings set delivery_fee_enabled = true, fee_tiers = '[{"up_to_km":5,"fee":10000},{"up_to_km":25,"fee":-20000}]';
do $$ declare o jsonb; begin
  o := public.create_order(null, '[{"variant_id":1,"quantity":1}]', null, 'Far', '081234567890', null, 'Jl. Jauh', null, 60, -6.65, 106.78);
  perform t.ok('OBS-14', (o->>'total')::int >= 0, 'an order total can never be negative', 'total ' || (o->>'total'));
exception when others then perform t.ok('OBS-14', true, 'an order total can never be negative', sqlerrm);
end $$;
update public.shop_settings set delivery_fee_enabled = false, fee_tiers = '[]';

-- ---------------------------------------------------------------- OBS-15: promo codes are no longer normalised
insert into public.promotions (name, code, discount_type, value, announce) values ('Spaces', ' hemat10 ', 'fixed', 1000, false);
select t.ok('OBS-15', exists (select 1 from public.promotions where name = 'Spaces' and code = 'HEMAT10'),
            'a promo code is stored trimmed and upper-case',
            'stored as [' || (select code from public.promotions where name = 'Spaces') || ']');

-- ---------------------------------------------------------------- OBS-16: deleting an account frees its vouchers for anyone
insert into public.vouchers (code, source, user_id, discount_type, value, assigned_at)
  values ('ONLY-FOR-D', 'admin', '00000000-0000-0000-0000-0000000000d1', 'fixed', 20000, now());
delete from auth.users where id = '00000000-0000-0000-0000-0000000000d1';
do $$ declare o jsonb; begin
  o := public.create_order('00000000-0000-0000-0000-0000000000b1', '[{"variant_id":1,"quantity":2}]', 'ONLY-FOR-D', 'B', '081234567892');
  perform t.ok('OBS-16', false, 'a deleted customer''s voucher can''t be used by someone else', 'another customer got discount ' || (o->>'discount'));
exception when others then perform t.ok('OBS-16', true, 'a deleted customer''s voucher can''t be used by someone else', sqlerrm);
end $$;

-- ---------------------------------------------------------------- OBS-17: notification promises 30 minutes, order is held 60
do $$ declare o jsonb; b text; m int; begin
  o := public.create_order('00000000-0000-0000-0000-00000000000c', '[{"variant_id":1,"quantity":1}]', null, 'C', '081234567893', null, null, null, 60);
  b := (select body from public.notifications where ref_id = t.num(o) order by id desc limit 1);
  m := (select round(extract(epoch from expires_at - created_at) / 60) from public.orders where order_number = t.num(o));
  perform t.ok('OBS-17', b is not null and position(m || ' menit' in b) > 0 or (b not like '%menit%'),
               'the "order created" notification states the real payment window', 'window ' || m || ' min; text: ' || coalesce(b, 'none'));
end $$;

-- ---------------------------------------------------------------- OBS-8: promo codes stay secret until live
insert into public.promotions (name, code, discount_type, value, is_active, announce) values ('Staff only', 'STAFF90', 'percent', 90, false, true);
create table t.c_order as select public.create_order('00000000-0000-0000-0000-00000000000c', '[{"variant_id":1,"quantity":1}]', null, 'C', '081234567893') as o;
create table t.ids as select (select id from public.promotions where code = 'STAFF90') as staff_promo, (select t.num(o) from t.c_order) as c_order_number;
grant select on t.c_order, t.ids to anon, authenticated;
begin;
set local role anon;   -- anon can't read promotions; it only knows (or guesses) the sequential id
select t.ok('OBS-8', (public.promo_details((select staff_promo from t.ids))->>'code') is null,
            'promo_details does not reveal the code of an inactive promo',
            'anon got code ' || coalesce(public.promo_details((select staff_promo from t.ids))->>'code', 'NULL'));
commit;

-- ---------------------------------------------------------------- cashflow (as admin)
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);

-- OBS-6: unpaid banner counts every date, its "Lihat" list shows only the period
do $$ declare banner int; listed int; begin
  perform public.cashflow_save_offline_order('{"client_token":"10000000-0000-0000-0000-0000000000a1","order_date":"2026-08-20T10:00:00+07:00","source":"walk_in","payment_method":"cash","entry_mode":"amount","amount":7000,"payment_status":"unpaid"}');
  banner := (public.cashflow_summary('2026-11-01', '2026-11-08')->>'unpaid_offline_orders')::int;
  listed := (public.cashflow_transactions('{"from":"2026-11-01","to":"2026-11-08","source":"offline","payment_status":"unpaid"}')->>'total_count')::int;
  perform t.ok('OBS-6', banner = listed, 'the "belum dibayar" banner count matches the list its "Lihat" link opens', 'banner ' || banner || ', list ' || listed);
exception when others then perform t.ok('OBS-6', false, 'the unpaid banner count matches its list', 'error: ' || sqlerrm);
end $$;

-- OBS-19: "card" documented as supported for expenses and offline sales (docs.html, commit db2f74b)
do $$ begin
  perform public.cashflow_save_expense('{"client_token":"20000000-0000-0000-0000-000000000001","expense_date":"2026-11-01T10:00:00+07:00","description":"Kartu test","category_id":1,"amount":1000,"payment_method":"card"}');
  perform t.ok('OBS-19', true, 'an expense paid by card can be saved, as docs.html says', null);
exception when others then perform t.ok('OBS-19', false, 'an expense paid by card can be saved, as docs.html says', sqlerrm);
end $$;

-- OBS-21: a sale paid a day before it was ordered lands in the previous month
do $$ begin
  perform public.cashflow_save_offline_order('{"client_token":"10000000-0000-0000-0000-0000000000a2","order_date":"2026-11-01T05:00:00+07:00","paid_at":"2026-10-31T06:00:00+07:00","source":"walk_in","payment_method":"cash","entry_mode":"amount","amount":7000,"payment_status":"paid"}');
  perform t.ok('OBS-21', false, 'payment time can''t be before the order time', 'accepted; counted in ' || (select to_char(paid_at at time zone 'Asia/Jakarta', 'Mon') from public.offline_orders where client_token = '10000000-0000-0000-0000-0000000000a2'));
exception when others then perform t.ok('OBS-21', true, 'payment time can''t be before the order time', sqlerrm);
end $$;

-- OBS-20: out-of-range input gives a raw database error
do $$ begin
  perform public.cashflow_transactions('{"from":"2026-10-01","to":"2026-11-30","page":2147483647}');
  perform t.ok('OBS-20', true, 'a huge page number is handled without a database error', null);
exception when others then perform t.ok('OBS-20', sqlerrm not like '%out of range%', 'a huge page number is handled without a database error', sqlerrm);
end $$;

-- OBS-7 (last): tests/db/run.sh has just tried to re-run migration 014 on its own against this database
-- (and checked that 014 refused). Cashflow must still work and migration 017's fixes must still be in place.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
do $$ begin
  perform public.cashflow_save_offline_order('{"client_token":"10000000-0000-0000-0000-0000000000a3","order_date":"2026-11-02T10:00:00+07:00","source":"walk_in","payment_method":"cash","entry_mode":"amount","amount":5000}');
  perform t.ok('OBS-7', true, 'after an attempt to re-run 014 alone, offline sales still save', null);
exception when others then perform t.ok('OBS-7', false, 'after an attempt to re-run 014 alone, offline sales still save', sqlerrm);
end $$;
select t.ok('OBS-7', pg_get_functiondef('public.cashflow_transactions(jsonb)'::regprocedure) like '%OBS-6%', 'migration 017''s fixes are still in place', null);

-- ---------------------------------------------------------------- report
\o
select id, case when ok then 'PASS' else 'FAIL' end as result, name, case when ok then '' else info end as info from t.results order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.results;
do $$ begin
  if exists (select 1 from t.results where not ok) then raise exception 'SOME TESTS FAILED'; end if;
end $$;
