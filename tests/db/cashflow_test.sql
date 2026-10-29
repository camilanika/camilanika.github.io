-- =====================================================================
-- Cashflow Summary: database tests (migration 014)
-- Run with tests/db/run.sh — builds a fresh database from the repo, then runs this file.
-- Test dates are in August 2026 (in the past), so results don't depend on today's date.
-- Each check writes a row to t.results; the script fails if any check fails.
-- Numbers in comments refer to section 10 of the feature request.
-- =====================================================================
\set ON_ERROR_STOP 1
set client_min_messages = warning;
\o /dev/null

create schema t;
create table t.results (n serial primary key, name text not null, ok boolean not null, info text);
create table t.ids (k text primary key, v text);
grant usage on schema t to anon, authenticated;
grant all on all tables in schema t to anon, authenticated;
grant all on all sequences in schema t to anon, authenticated;

create function t.ok(c boolean, name text, info text default null) returns void language sql as $$
  insert into t.results (name, ok, info) values (name, coalesce(c, false), info) $$;
create function t.eq(got anyelement, want anyelement, name text) returns void language sql as $$
  insert into t.results (name, ok, info) values (name, got is not distinct from want, 'got ' || coalesce(got::text, 'NULL') || ', want ' || coalesce(want::text, 'NULL')) $$;
create function t.throws(q text, expect text, name text) returns void language plpgsql as $$
begin
  execute q;
  perform t.ok(false, name, 'no error raised');
exception when others then
  perform t.ok(sqlerrm like '%' || expect || '%', name, sqlerrm);
end $$;
create function t.id(k text) returns text language sql stable as $$ select v from t.ids where k = $1 $$;
create function t.put(k text, v text) returns void language sql as $$
  insert into t.ids values (k, v) on conflict (k) do update set v = excluded.v $$;
grant execute on all functions in schema t to anon, authenticated;

-- ---------------------------------------------------------------- fixtures (as the database owner)
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@test.local'),
  ('00000000-0000-0000-0000-00000000000c', 'customer@test.local');
update public.profiles set role = 'admin', full_name = 'Admin Tes' where id = '00000000-0000-0000-0000-00000000000a';
update public.inventory set unlimited = true;   -- the seed's placeholder stock of 10 is not under test

-- the shop is in Sandbox by default
select t.eq((select payments_mode from public.shop_settings where id = 1), 'sandbox', 'settings: payments_mode defaults to sandbox');

-- online order helper: creates through the real create_order / mark_order_paid / admin_set_order_status path
create function t.order(p_items jsonb, p_env text, p_status text, p_completed timestamptz default null)
returns uuid language plpgsql as $$
declare o jsonb; v_id uuid;
begin
  o := public.create_order(null, p_items, null, 'Tes Pelanggan', '081234567890');
  v_id := (select id from public.orders where order_number = o->>'order_number');
  if p_env is not null then perform public.tag_order_payment_env(o->>'order_number', p_env); end if;
  if p_status in ('paid','processing','completed','cancelled') then
    perform public.mark_order_paid(o->>'order_number', 'ref-' || left(v_id::text, 8), 'qris');
  end if;
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
  if p_status in ('processing','completed','cancelled') then
    perform public.admin_set_order_status(v_id, p_status);
  end if;
  if p_status in ('expired','failed') then perform public.release_order(o->>'order_number', p_status); end if;
  perform set_config('request.jwt.claim.sub', '', false);
  -- place the completion inside the test period (the trigger stamped now())
  if p_completed is not null then update public.orders set completed_at = p_completed where id = v_id; end if;
  return v_id;
end $$;

-- 1 real completed order: 2x Americano S (13.000) + 1x Matcha Latte S (18.500) = 44.500
select t.put('o_real1', t.order('[{"variant_id":1,"quantity":2},{"variant_id":34,"quantity":1}]', 'production', 'completed', '2026-08-10 10:00+07')::text);
-- 2 real completed order: 1x Americano S = 13.000
select t.put('o_real2', t.order('[{"variant_id":1,"quantity":1}]', 'production', 'completed', '2026-08-12 15:00+07')::text);
-- 3 mock completed order (sandbox): 3x Chocolate S (16.500) = 49.500
select t.put('o_mock1', t.order('[{"variant_id":25,"quantity":3}]', 'sandbox', 'completed', '2026-08-11 09:00+07')::text);
-- not completed: pending, paid, processing, cancelled-after-paid, expired, failed (all production)
select t.put('o_pending', t.order('[{"variant_id":1,"quantity":5}]', 'production', 'pending')::text);
select t.put('o_paid',    t.order('[{"variant_id":1,"quantity":5}]', 'production', 'paid')::text);
select t.put('o_proc',    t.order('[{"variant_id":1,"quantity":5}]', 'production', 'processing')::text);
select t.put('o_cancel',  t.order('[{"variant_id":1,"quantity":5}]', 'production', 'cancelled')::text);
select t.put('o_expired', t.order('[{"variant_id":1,"quantity":5}]', 'production', 'expired')::text);
select t.put('o_failed',  t.order('[{"variant_id":1,"quantity":5}]', 'production', 'failed')::text);
-- an order whose environment was never reported: falls back to payments_mode (sandbox -> mock)
select t.put('o_untagged', t.order('[{"variant_id":1,"quantity":1}]', null, 'completed', '2026-08-13 12:00+07')::text);
-- completed outside the period (31 Jul 23:59 WIB and 1 Sep 00:00 WIB)
select t.put('o_before', t.order('[{"variant_id":1,"quantity":1}]', 'production', 'completed', '2026-07-31 23:59:59+07')::text);
select t.put('o_after',  t.order('[{"variant_id":1,"quantity":1}]', 'production', 'completed', '2026-09-01 00:00:00+07')::text);

select t.eq((select classification from public.orders where id = t.id('o_real1')::uuid), 'real', 'classify: production order is real');
select t.eq((select classification from public.orders where id = t.id('o_mock1')::uuid), 'mock', 'classify: sandbox order is mock');
select t.eq((select classification from public.orders where id = t.id('o_untagged')::uuid), 'mock', 'classify: untagged order follows payments_mode (sandbox)');
select t.ok((select completed_at is not null and not completed_at_estimated from public.orders where id = t.id('o_real2')::uuid), 'completion date is stamped when an order becomes completed');
select t.ok((select completed_at is null from public.orders where id = t.id('o_proc')::uuid), 'processing order has no completion date');

-- ---------------------------------------------------------------- as admin
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);

-- 1, 2, 3, 25: summary
do $$
declare s jsonb := public.cashflow_summary('2026-08-01', '2026-08-31');
begin
  perform t.eq((s->>'real_order_income')::bigint, 57500::bigint, '#1/#25 real order income = 44.500 + 13.000');
  perform t.eq((s->>'completed_real_orders')::int, 2, '#1/#2 completed real orders counted, pending/paid/processing/cancelled/expired/failed excluded');
  perform t.eq((s->>'mock_order_value')::bigint, 62500::bigint, '#3 mock value = 49.500 + untagged 13.000');
  perform t.eq((s->>'total_income')::bigint, 57500::bigint, '#3 mock orders not in total income');
  perform t.eq((s->>'total_items_sold')::bigint, 4::bigint, '#25 items sold counts only real lines (2+1+1)');
  perform t.eq((s->>'net_cashflow')::bigint, 57500::bigint, '#25 net cashflow with no expenses');
end $$;

-- 4, 5: reclassification
do $$
declare s jsonb;
begin
  perform public.cashflow_set_order_classification(t.id('o_mock1')::uuid, 'real', 'pembelian teman, dibayar');
  s := public.cashflow_summary('2026-08-01', '2026-08-31');
  perform t.eq((s->>'real_order_income')::bigint, 107000::bigint, '#4 mock -> real adds the order to income');
  perform t.eq((s->>'completed_real_orders')::int, 3, '#4 mock -> real counted once');
  perform t.eq((select status from public.orders where id = t.id('o_mock1')::uuid), 'completed', '#4 reclassifying does not change order status');
  perform t.eq((select total from public.orders where id = t.id('o_mock1')::uuid), 49500, '#4 reclassifying does not change order total');
  perform public.cashflow_set_order_classification(t.id('o_mock1')::uuid, 'real');  -- same again: no double count
  s := public.cashflow_summary('2026-08-01', '2026-08-31');
  perform t.eq((s->>'real_order_income')::bigint, 107000::bigint, '#6 repeating a classification does not inflate income');
  perform public.cashflow_set_order_classification(t.id('o_mock1')::uuid, 'mock');
  s := public.cashflow_summary('2026-08-01', '2026-08-31');
  perform t.eq((s->>'real_order_income')::bigint, 57500::bigint, '#5 real -> mock removes it from income');
  perform t.eq((s->>'mock_order_value')::bigint, 62500::bigint, '#5 and it is back in mock value');
  perform t.eq((select classification_source from public.orders where id = t.id('o_mock1')::uuid), 'admin', 'admin choice is remembered');
  perform t.ok((select count(*) = 3 from public.cashflow_audit where entity = 'order' and entity_id = t.id('o_mock1')), 'classification changes are audited');
end $$;

-- an admin choice is not overwritten by a later Midtrans notification
reset role;
select public.tag_order_payment_env((select order_number from public.orders where id = t.id('o_mock1')::uuid), 'production');
select t.eq((select classification from public.orders where id = t.id('o_mock1')::uuid), 'mock', 'webhook tag does not override an admin classification');
-- 6: the webhook tagging twice / mark_order_paid twice changes nothing
select public.mark_order_paid((select order_number from public.orders where id = t.id('o_real2')::uuid), 'dup', 'qris');
select public.tag_order_payment_env((select order_number from public.orders where id = t.id('o_real2')::uuid), 'production');
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select t.eq((public.cashflow_summary('2026-08-01', '2026-08-31')->>'real_order_income')::bigint, 57500::bigint, '#6 repeated payment notifications do not inflate income');

-- 8, 20, 22: offline order with several items
do $$
declare r jsonb; s jsonb;
begin
  r := public.cashflow_save_offline_order(jsonb_build_object(
    'client_token', '11111111-1111-1111-1111-111111111111', 'order_date', '2026-08-15T11:00:00+07:00',
    'order_ref', 'NOTA-001', 'customer_name', 'Bu Rina', 'source', 'walk_in', 'payment_method', 'cash',
    'items', jsonb_build_array(
      jsonb_build_object('variant_id', 1, 'quantity', 3),                                     -- 3 x 13.000 = 39.000
      jsonb_build_object('variant_id', 34, 'quantity', 2, 'unit_price', 18000, 'discount', 1000), -- 36.000 - 1.000 = 35.000
      jsonb_build_object('product_name', 'Es batu tambahan', 'quantity', 1, 'unit_price', 2000)),  -- 2.000
    'order_discount', 5000, 'extra_charge', 4000, 'expected_total', 75000));
  perform t.put('off1', r->>'id');
  perform t.eq((r->>'total')::int, 75000, '#8/#20 offline total = 39.000 + 35.000 + 2.000 - 5.000 + 4.000');
  perform t.eq((select count(*)::int from public.offline_order_items where offline_order_id = (r->>'id')::bigint), 3, '#8 three item lines saved');
  perform t.eq((select section_name from public.offline_order_items where offline_order_id = (r->>'id')::bigint and variant_id = 34), 'Matcha Series', 'offline line keeps a category snapshot');
  perform t.eq((select classification from public.offline_orders where id = (r->>'id')::bigint), 'real', 'offline order defaults to real');
  s := public.cashflow_summary('2026-08-01', '2026-08-31');
  perform t.eq((s->>'offline_order_income')::bigint, 75000::bigint, '#25 offline income');
  perform t.eq((s->>'total_income')::bigint, 132500::bigint, '#25 total income = real orders + offline');
  perform t.eq((s->>'total_items_sold')::bigint, 10::bigint, '#22 offline items count toward items sold (4 + 6)');
end $$;

-- 6: the same submission twice saves once
do $$
declare r jsonb;
begin
  r := public.cashflow_save_offline_order(jsonb_build_object(
    'client_token', '11111111-1111-1111-1111-111111111111', 'order_date', '2026-08-15T11:00:00+07:00',
    'source', 'walk_in', 'payment_method', 'cash', 'items', '[{"variant_id":1,"quantity":3}]'::jsonb));
  perform t.ok((r->>'duplicate')::boolean and (r->>'id') = t.id('off1'), '#6 resubmitted offline order returns the saved one');
  perform t.eq((select count(*)::int from public.offline_orders), 1, '#6 no duplicate offline order row');
end $$;

-- 29: backend validation of manipulated amounts
select t.throws($q$select public.cashflow_save_offline_order('{"client_token":"22222222-2222-2222-2222-222222222222","order_date":"2026-08-15T12:00:00+07:00","source":"walk_in","payment_method":"cash","items":[{"variant_id":1,"quantity":1}],"expected_total":1000}')$q$, 'TOTAL_MISMATCH', '#29 manipulated client total is rejected');
select t.throws($q$select public.cashflow_save_offline_order('{"client_token":"22222222-2222-2222-2222-222222222222","order_date":"2026-08-15T12:00:00+07:00","source":"walk_in","payment_method":"cash","items":[{"variant_id":1,"quantity":-2}]}')$q$, 'INVALID_QUANTITY', '#29 negative quantity rejected');
select t.throws($q$select public.cashflow_save_offline_order('{"client_token":"22222222-2222-2222-2222-222222222222","order_date":"2026-08-15T12:00:00+07:00","source":"walk_in","payment_method":"cash","items":[{"variant_id":1,"quantity":1,"discount":20000}]}')$q$, 'INVALID_ITEM_DISCOUNT', '#29 discount above line value rejected');
select t.throws($q$select public.cashflow_save_offline_order('{"client_token":"22222222-2222-2222-2222-222222222222","order_date":"2026-08-15T12:00:00+07:00","source":"walk_in","payment_method":"cash","items":[{"variant_id":1,"quantity":1,"unit_price":"13000.5"}]}')$q$, 'INVALID_NUMBER', '#29 decimal price rejected');
select t.throws($q$select public.cashflow_save_offline_order('{"client_token":"22222222-2222-2222-2222-222222222222","order_date":"2026-08-15T12:00:00+07:00","source":"walk_in","payment_method":"cash","items":[{"variant_id":1,"quantity":1}],"order_discount":99999}')$q$, 'ORDER_DISCOUNT_TOO_LARGE', '#29 order discount above subtotal rejected');
select t.throws($q$select public.cashflow_save_offline_order('{"client_token":"22222222-2222-2222-2222-222222222222","order_date":"2026-08-15T12:00:00+07:00","source":"walk_in","payment_method":"crypto","items":[{"variant_id":1,"quantity":1}]}')$q$, 'INVALID_PAYMENT_METHOD', 'offline payment method must be one of the list');
select t.throws($q$select public.cashflow_save_offline_order('{"client_token":"22222222-2222-2222-2222-222222222222","order_date":"2026-08-15T12:00:00+07:00","source":"walk_in","payment_method":"cash","items":[]}')$q$, 'ITEMS_REQUIRED', 'item order needs at least one item');
select t.throws($q$select public.cashflow_save_offline_order('{"client_token":"22222222-2222-2222-2222-222222222222","order_date":"2099-01-01T12:00:00+07:00","source":"walk_in","payment_method":"cash","items":[{"variant_id":1,"quantity":1}]}')$q$, 'DATE_IN_FUTURE', 'future offline order date rejected');
-- 13: an online order number can't be recorded again as offline
select t.throws(format($q$select public.cashflow_save_offline_order('{"client_token":"22222222-2222-2222-2222-222222222222","order_date":"2026-08-15T12:00:00+07:00","order_ref":"%s","source":"whatsapp","payment_method":"cash","amount":13000,"entry_mode":"amount"}')$q$,
  (select order_number from public.orders where id = t.id('o_real2')::uuid)), 'REF_IS_ONLINE_ORDER', '#13 online order number cannot be recorded as offline (no double count)');
select t.throws($q$select public.cashflow_save_offline_order('{"client_token":"22222222-2222-2222-2222-222222222222","order_date":"2026-08-15T12:00:00+07:00","order_ref":"nota-001","source":"walk_in","payment_method":"cash","amount":5000,"entry_mode":"amount"}')$q$, 'DUPLICATE_REF', '#13 the same receipt number cannot be recorded twice');

-- 11: amount-only offline order
do $$
declare r jsonb; s jsonb; m jsonb;
begin
  r := public.cashflow_save_offline_order('{"client_token":"33333333-3333-3333-3333-333333333333","order_date":"2026-08-16T19:00:00+07:00","source":"whatsapp","payment_method":"bank_transfer","entry_mode":"amount","amount":"120000","customer_name":"Grup arisan"}');
  perform t.put('off_amt', r->>'id');
  s := public.cashflow_summary('2026-08-01', '2026-08-31');
  perform t.eq((s->>'offline_order_income')::bigint, 195000::bigint, '#11 amount-only order counts toward offline income');
  perform t.eq((s->>'total_items_sold')::bigint, 10::bigint, '#11 amount-only order adds no items');
  m := public.cashflow_menu_sales('2026-08-01', '2026-08-31');
  perform t.eq((m->'amount_only'->>'orders')::int, 1, '#23 amount-only orders are disclosed (count)');
  perform t.eq((m->'amount_only'->>'value')::bigint, 120000::bigint, '#23 amount-only orders are disclosed (value)');
  perform t.ok(not exists (select 1 from jsonb_array_elements(m->'rows') x where (x->>'revenue')::bigint = 120000), '#23 amount-only value not assigned to any menu item');
end $$;
select t.throws($q$select public.cashflow_save_offline_order('{"client_token":"44444444-4444-4444-4444-444444444444","order_date":"2026-08-16T19:00:00+07:00","source":"whatsapp","payment_method":"cash","entry_mode":"amount","amount":0}')$q$, 'AMOUNT_MUST_BE_POSITIVE', 'amount-only order needs a positive amount');

-- 12: mock offline order
do $$
declare r jsonb; s jsonb;
begin
  r := public.cashflow_save_offline_order('{"client_token":"55555555-5555-5555-5555-555555555555","order_date":"2026-08-17T10:00:00+07:00","source":"other","payment_method":"cash","classification":"mock","items":[{"variant_id":25,"quantity":10}]}');
  perform t.put('off_mock', r->>'id');
  s := public.cashflow_summary('2026-08-01', '2026-08-31');
  perform t.eq((s->>'total_income')::bigint, 252500::bigint, '#12 mock offline order not in total income');
  perform t.eq((s->>'mock_offline_value')::bigint, 165000::bigint, '#12 mock offline order in mock value');
  perform t.eq((s->>'total_items_sold')::bigint, 10::bigint, '#12 mock offline items not in items sold');
end $$;

-- 9: edit and delete an offline order (with version check)
do $$
declare r jsonb; v int; s jsonb;
begin
  v := (select version from public.offline_orders where id = t.id('off1')::bigint);
  r := public.cashflow_save_offline_order(jsonb_build_object('id', t.id('off1')::bigint, 'version', v,
    'order_date', '2026-08-15T11:00:00+07:00', 'order_ref', 'NOTA-001', 'source', 'walk_in', 'payment_method', 'qris',
    'items', '[{"variant_id":1,"quantity":4}]'::jsonb));
  perform t.eq((r->>'total')::int, 52000, '#9 edited offline order recalculated on the server');
  perform t.eq((select count(*)::int from public.offline_order_items where offline_order_id = t.id('off1')::bigint), 1, '#9 edit replaces the item lines');
  perform t.eq((public.cashflow_summary('2026-08-01', '2026-08-31')->>'offline_order_income')::bigint, 172000::bigint, '#9 edit updates income (52.000 + 120.000)');
  perform t.throws(format('select public.cashflow_save_offline_order(%L)', jsonb_build_object('id', t.id('off1')::bigint, 'version', v,
    'order_date', '2026-08-15T11:00:00+07:00', 'source', 'walk_in', 'payment_method', 'cash', 'items', '[{"variant_id":1,"quantity":1}]'::jsonb)),
    'STALE_RECORD', 'concurrent edit with an old version is rejected');
  perform t.throws(format('select public.cashflow_delete_offline_order(%s, %s)', t.id('off1'), v), 'STALE_RECORD', 'delete with an old version is rejected');
  perform public.cashflow_delete_offline_order(t.id('off1')::bigint, v + 1);
  s := public.cashflow_summary('2026-08-01', '2026-08-31');
  perform t.eq((s->>'offline_order_income')::bigint, 120000::bigint, '#9 deleted offline order leaves the totals');
  perform t.ok((select deleted_at is not null from public.offline_orders where id = t.id('off1')::bigint), 'offline delete is a soft delete (kept for audit)');
  perform t.eq((select string_agg(action, ',' order by id) from public.cashflow_audit where entity = 'offline_order' and entity_id = t.id('off1')), 'create,update,delete', 'offline order history audited');
  perform t.throws(format('select public.cashflow_delete_offline_order(%s, %s)', t.id('off1'), v + 2), 'RECORD_NOT_FOUND', 'cannot delete twice');
  -- the receipt number is free again once deleted
  r := public.cashflow_save_offline_order('{"client_token":"66666666-6666-6666-6666-666666666666","order_date":"2026-08-15T11:00:00+07:00","order_ref":"NOTA-001","source":"walk_in","payment_method":"cash","items":[{"variant_id":1,"quantity":1}]}');
  perform t.put('off2', r->>'id');
  perform t.ok((r->>'id') is not null, 'receipt number can be reused after its order is deleted');
end $$;

-- 14, 15, 16, 17: expenses
do $$
declare r jsonb; cat bigint; s jsonb; v int;
begin
  cat := (select id from public.expense_categories where name = 'Packaging');
  r := public.cashflow_save_expense(jsonb_build_object('client_token', '77777777-7777-7777-7777-777777777777',
    'expense_date', '2026-08-31T23:30:00+07:00', 'description', 'Botol 250 ml', 'category_id', cat,
    'amount', 30000, 'payment_method', 'qris', 'vendor', 'Toko Plastik Jaya'));
  perform t.put('exp1', r->>'id');
  perform t.eq((select category_name || '|' || payment_method || '|' || amount from public.expenses where id = (r->>'id')::bigint), 'Packaging|qris|30000', '#16 category and payment method stored');
  -- just outside the period on either side
  perform public.cashflow_save_expense(jsonb_build_object('client_token', '77777777-0000-0000-0000-000000000001',
    'expense_date', '2026-09-01T00:00:00+07:00', 'description', 'Bulan depan', 'category_id', cat, 'amount', 1, 'payment_method', 'cash'));
  perform public.cashflow_save_expense(jsonb_build_object('client_token', '77777777-0000-0000-0000-000000000002',
    'expense_date', '2026-07-31T23:59:59+07:00', 'description', 'Bulan lalu', 'category_id', cat, 'amount', 1, 'payment_method', 'cash'));
  s := public.cashflow_summary('2026-08-01', '2026-08-31');
  perform t.eq((s->>'total_expenses')::bigint, 30000::bigint, '#14/#26 expense on 31 Aug 23:30 WIB counted, 31 Jul / 1 Sep not');
  perform t.eq((s->>'net_cashflow')::bigint, 160500::bigint, '#17 net cashflow = (57.500 + 120.000 + 13.000) - 30.000');
  v := (select version from public.expenses where id = (r->>'id')::bigint);
  perform public.cashflow_save_expense(jsonb_build_object('id', (r->>'id')::bigint, 'version', v,
    'expense_date', '2026-08-31T23:30:00+07:00', 'description', 'Botol 250 ml (100 pcs)', 'category_id', cat,
    'amount', 45000, 'payment_method', 'qris'));
  s := public.cashflow_summary('2026-08-01', '2026-08-31');
  perform t.eq((s->>'total_expenses')::bigint, 45000::bigint, '#14/#17 edited expense updates total expenses');
  perform t.eq((s->>'net_cashflow')::bigint, (s->>'total_income')::bigint - 45000, '#17 net cashflow = total income - total expenses');
  r := public.cashflow_save_expense(jsonb_build_object('client_token', '77777777-7777-7777-7777-777777777777',
    'expense_date', '2026-08-31T23:30:00+07:00', 'description', 'Botol 250 ml', 'category_id', cat, 'amount', 30000, 'payment_method', 'qris'));
  perform t.ok((r->>'duplicate')::boolean, '#6 double-submitted expense saved once');
  perform public.cashflow_delete_expense(t.id('exp1')::bigint, v + 1);
  perform t.eq((public.cashflow_summary('2026-08-01', '2026-08-31')->>'total_expenses')::bigint, 0::bigint, '#14 deleted expense leaves the totals');
end $$;
select t.throws($q$select public.cashflow_save_expense('{"client_token":"88888888-8888-8888-8888-888888888888","expense_date":"2026-08-20T10:00:00+07:00","description":"x","category_id":1,"amount":0,"payment_method":"cash"}')$q$, 'AMOUNT_MUST_BE_POSITIVE', '#15 zero expense rejected');
select t.throws($q$select public.cashflow_save_expense('{"client_token":"88888888-8888-8888-8888-888888888888","expense_date":"2026-08-20T10:00:00+07:00","description":"x","category_id":1,"amount":-500,"payment_method":"cash"}')$q$, 'AMOUNT_MUST_BE_POSITIVE', '#15 negative expense rejected');
select t.throws($q$select public.cashflow_save_expense('{"client_token":"88888888-8888-8888-8888-888888888888","expense_date":"2026-08-20T10:00:00+07:00","description":"x","category_id":1,"amount":"abc","payment_method":"cash"}')$q$, 'INVALID_NUMBER', '#15 non-numeric expense rejected');
select t.throws($q$select public.cashflow_save_expense('{"client_token":"88888888-8888-8888-8888-888888888888","expense_date":"2026-08-20T10:00:00+07:00","description":"x","category_id":1,"amount":10.5,"payment_method":"cash"}')$q$, 'INVALID_NUMBER', '#15 fractional Rupiah rejected');
select t.throws($q$select public.cashflow_save_expense('{"client_token":"88888888-8888-8888-8888-888888888888","expense_date":"2026-08-20T10:00:00+07:00","description":"x","category_id":1,"amount":99999999999,"payment_method":"cash"}')$q$, 'NUMBER_TOO_LARGE', '#15 absurdly large expense rejected');
select t.throws($q$select public.cashflow_save_expense('{"client_token":"88888888-8888-8888-8888-888888888888","expense_date":"2026-08-20T10:00:00+07:00","description":"  ","category_id":1,"amount":100,"payment_method":"cash"}')$q$, 'DESCRIPTION_REQUIRED', 'expense needs a description');
select t.throws($q$select public.cashflow_save_expense('{"client_token":"88888888-8888-8888-8888-888888888888","expense_date":"2026-08-20T10:00:00+07:00","description":"x","amount":100,"payment_method":"cash"}')$q$, 'CATEGORY_REQUIRED', 'expense needs a category');

-- categories: 11 defaults, rename keeps history, hide instead of delete
do $$
declare cid bigint; r jsonb; v int;
begin
  perform t.eq((select count(*)::int from public.expense_categories where is_default), 11, 'eleven default expense categories');
  cid := public.cashflow_save_category(null, 'Gas LPG');
  r := public.cashflow_save_expense(jsonb_build_object('client_token', '99999999-9999-9999-9999-999999999999',
    'expense_date', '2026-08-20T10:00:00+07:00', 'description', 'Isi ulang gas', 'category_id', cid, 'amount', 22000, 'payment_method', 'cash'));
  perform public.cashflow_save_category(cid, 'Gas & Bahan Bakar', false);
  perform t.eq((select category_name from public.expenses where id = (r->>'id')::bigint), 'Gas LPG', 'renaming a category keeps the name on past expenses');
  perform t.throws(format('select public.cashflow_save_expense(%L)', jsonb_build_object('client_token', '99999999-0000-0000-0000-000000000001',
    'expense_date', '2026-08-20T10:00:00+07:00', 'description', 'x', 'category_id', cid, 'amount', 1, 'payment_method', 'cash')), 'CATEGORY_INACTIVE', 'hidden category cannot be chosen for a new expense');
  v := (select version from public.expenses where id = (r->>'id')::bigint);
  perform public.cashflow_save_expense(jsonb_build_object('id', (r->>'id')::bigint, 'version', v,
    'expense_date', '2026-08-20T10:00:00+07:00', 'description', 'Isi ulang gas 3 kg', 'category_id', cid, 'amount', 22000, 'payment_method', 'cash'));
  perform t.ok(true, 'an old expense can still be edited while its category is hidden');
  perform t.throws($q$select public.cashflow_save_category(null, 'packaging')$q$, 'DUPLICATE_NAME', 'category names are unique (case-insensitive)');
end $$;

-- 18, 19, 21, 24: menu analytics
do $$
declare m jsonb; am jsonb; mk jsonb; v jsonb; d jsonb;
begin
  -- real lines in Aug: o_real1 (2x Americano 26.000, 1x Matcha 18.500), o_real2 (1x Americano 13.000), off2 (1x Americano 13.000)
  m := public.cashflow_menu_sales('2026-08-01', '2026-08-31');
  select x into am from jsonb_array_elements(m->'rows') x where x->>'name' = 'Americano';
  perform t.eq((am->>'quantity')::bigint, 4::bigint, '#18 Americano quantity summed across orders (2+1+1)');
  perform t.eq((am->>'revenue')::bigint, 52000::bigint, '#18 Americano revenue summed across orders');
  perform t.eq((am->>'avg_price')::numeric, 13000::numeric, '#20 average selling price');
  perform t.eq((m->>'total_revenue')::bigint, 70500::bigint, '#18 total menu revenue');
  perform t.eq((am->>'share')::numeric, 73.8, '#18 share of menu revenue (52.000 / 70.500)');
  perform t.ok(not exists (select 1 from jsonb_array_elements(m->'rows') x where x->>'name' = 'Chocolate'), '#21 mock orders excluded from real menu stats');
  perform t.eq((m->'insights'->'top_by_quantity'->>'name'), 'Americano', 'insight: best seller by quantity');
  perform t.eq((m->'insights'->'top_category'->>'name'), 'Coffee Series', 'insight: best category');
  perform t.eq((select (x->>'revenue')::bigint from jsonb_array_elements(m->'categories') x where x->>'name' = 'Matcha Series'), 18500::bigint, 'category totals');
  -- mock scope shows them separately
  mk := public.cashflow_menu_sales('2026-08-01', '2026-08-31', 'mock');
  perform t.eq((select (x->>'quantity')::bigint from jsonb_array_elements(mk->'rows') x where x->>'name' = 'Chocolate'), 13::bigint, '#21 mock analysis available separately (3 online + 10 offline)');
  -- 19: date range
  d := public.cashflow_menu_sales('2026-08-12', '2026-08-12');
  perform t.eq((d->>'total_quantity')::bigint, 1::bigint, '#19 one day only includes that day''s orders');
  -- variant grouping
  v := public.cashflow_menu_sales('2026-08-01', '2026-08-31', 'real', 'variant');
  perform t.ok(exists (select 1 from jsonb_array_elements(v->'rows') x where x->>'name' = 'Americano' and x->>'variant' = 'S 250 ml'), 'variant grouping shows the size');
end $$;

-- 24: menu changes don't change history
reset role;
update public.product_variants set price = 99999 where id = 1;
update public.products set name = 'Americano Baru' where id = 1;
delete from public.product_variants where id = 34;   -- the Matcha Latte S variant disappears
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
do $$
declare m jsonb; s jsonb;
begin
  m := public.cashflow_menu_sales('2026-08-01', '2026-08-31');
  s := public.cashflow_summary('2026-08-01', '2026-08-31');
  perform t.eq((m->>'total_revenue')::bigint, 70500::bigint, '#24 price change / deleted variant does not alter past menu revenue');
  perform t.eq((select (x->>'quantity')::bigint from jsonb_array_elements(m->'rows') x where x->>'key' = 'p1'), 4::bigint, '#24 renamed product keeps its history in one row');
  perform t.eq((s->>'real_order_income')::bigint, 57500::bigint, '#24 order income unchanged by menu edits');
end $$;

-- 26, 27: transaction list filters and search
do $$
declare x jsonb;
begin
  x := public.cashflow_transactions('{"from":"2026-08-01","to":"2026-08-31"}');
  -- real1, real2, mock1, untagged, off_amt, off_mock, off2, gas expense
  perform t.eq((x->>'total_count')::int, 8, '#26 all eligible transactions in the period');
  perform t.ok((select bool_and(a >= b) from (select (r->>'at')::timestamptz a, lead((r->>'at')::timestamptz) over () b from jsonb_array_elements(x->'rows') r) z where b is not null), '#27 newest first');
  perform t.eq((public.cashflow_transactions('{"from":"2026-08-01","to":"2026-08-31","type":"expense"}')->>'total_count')::int, 1, '#27 filter: expenses');
  perform t.eq((public.cashflow_transactions('{"from":"2026-08-01","to":"2026-08-31","classification":"mock"}')->>'total_count')::int, 3, '#27 filter: mock only');
  perform t.eq((public.cashflow_transactions('{"from":"2026-08-01","to":"2026-08-31","source":"system_real"}')->>'total_count')::int, 2, '#27 filter: system real orders');
  perform t.eq((public.cashflow_transactions('{"from":"2026-08-01","to":"2026-08-31","source":"system"}')->>'total_count')::int, 4, '#27 filter: all completed online orders (real + mock)');
  perform t.eq((public.cashflow_transactions('{"from":"2026-08-01","to":"2026-08-31","source":"offline"}')->>'total_count')::int, 3, '#27 filter: offline orders');
  perform t.eq((public.cashflow_transactions('{"from":"2026-08-01","to":"2026-08-31","payment":"bank_transfer"}')->>'total_count')::int, 1, '#27 filter: payment method');
  perform t.eq((public.cashflow_transactions(jsonb_build_object('from','2026-08-01','to','2026-08-31','category_id',(select id from public.expense_categories where name = 'Gas & Bahan Bakar')))->>'total_count')::int, 1, '#27 filter: expense category');
  perform t.eq((public.cashflow_transactions('{"from":"2026-08-01","to":"2026-08-31","q":"matcha"}')->>'total_count')::int, 1, '#27 search: menu item');
  perform t.eq((public.cashflow_transactions('{"from":"2026-08-01","to":"2026-08-31","q":"arisan"}')->>'total_count')::int, 1, '#27 search: customer name');
  perform t.eq((public.cashflow_transactions('{"from":"2026-08-01","to":"2026-08-31","q":"nota-001"}')->>'total_count')::int, 1, '#27 search: receipt number');
  perform t.eq((public.cashflow_transactions('{"from":"2026-08-01","to":"2026-08-31","q":"isi ulang"}')->>'total_count')::int, 1, '#27 search: expense description');
  perform t.eq((public.cashflow_transactions(jsonb_build_object('from','2026-08-01','to','2026-08-31','q',(select order_number from public.orders where id = t.id('o_real1')::uuid)))->>'total_count')::int, 1, '#27 search: order number');
  perform t.eq((public.cashflow_transactions('{"from":"2026-08-01","to":"2026-08-31","review":true}')->>'total_count')::int, 0, 'filter: needs review (none in a fresh database)');
  perform t.eq((public.cashflow_transactions('{"from":"2026-08-01","to":"2026-08-31","q":"100%"}')->>'total_count')::int, 0, 'search treats % literally');
  x := public.cashflow_transactions('{"from":"2026-08-01","to":"2026-08-31","page":2,"page_size":3}');
  perform t.eq(jsonb_array_length(x->'rows'), 3, 'pagination: page 2 of 3');
  perform t.eq((public.cashflow_transactions('{"from":"2026-08-12","to":"2026-08-12"}')->>'total_count')::int, 1, '#26 same date range in the list as in the summary');
  perform t.throws($q$select public.cashflow_summary('2026-08-31', '2026-08-01')$q$, 'DATE_RANGE_INVALID', 'reversed date range rejected');
end $$;

-- payments mode switch: new orders become real, and the change is audited
select public.cashflow_set_payments_mode('production');
reset role;
select t.put('o_after_live', t.order('[{"variant_id":1,"quantity":1}]', null, 'completed')::text);
select t.eq((select classification from public.orders where id = t.id('o_after_live')::uuid), 'real', 'payments_mode production: untagged new orders are real');
select t.ok(exists (select 1 from public.cashflow_audit where entity = 'settings' and action = 'payments_mode'), 'payments_mode change audited');

-- 7: existing order flow still works (status transitions, notifications, loyalty untouched)
select t.eq((select status from public.orders where id = t.id('o_cancel')::uuid), 'cancelled', '#7 cancel flow unchanged');
select t.eq((select status from public.orders where id = t.id('o_proc')::uuid), 'processing', '#7 processing flow unchanged');

-- 28: unauthorized users
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
select t.throws($q$select public.cashflow_summary('2026-08-01', '2026-08-31')$q$, 'NOT_ADMIN', '#28 customer cannot read the summary');
select t.throws($q$select public.cashflow_transactions('{"from":"2026-08-01","to":"2026-08-31"}')$q$, 'NOT_ADMIN', '#28 customer cannot list transactions');
select t.throws($q$select public.cashflow_save_expense('{"client_token":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","expense_date":"2026-08-20T10:00:00+07:00","description":"x","category_id":1,"amount":100,"payment_method":"cash"}')$q$, 'NOT_ADMIN', '#28 customer cannot add expenses');
select t.throws(format('select public.cashflow_delete_offline_order(%s, 1)', t.id('off2')), 'NOT_ADMIN', '#28 customer cannot delete offline orders');
select t.throws(format('select public.cashflow_set_order_classification(%L, ''real'')', t.id('o_mock1')), 'NOT_ADMIN', '#28 customer cannot reclassify orders');
select t.throws($q$select public.cashflow_set_payments_mode('sandbox')$q$, 'NOT_ADMIN', '#28 customer cannot change payments mode');
select t.ok((select count(*) = 0 from public.expenses), '#28 customer cannot read expense rows directly (RLS)');
select t.ok((select count(*) = 0 from public.offline_orders), '#28 customer cannot read offline orders directly (RLS)');
select t.throws($q$insert into public.expenses (client_token, expense_date, description, category_name, amount, payment_method) values (gen_random_uuid(), now(), 'x', 'x', 1, 'cash')$q$, 'permission denied', '#28 no direct inserts');
select t.throws($q$select public.tag_order_payment_env('x', 'production')$q$, 'permission denied', '#28 only Edge Functions can tag the payment environment');
set role anon;
select set_config('request.jwt.claim.sub', '', false);
select t.throws($q$select public.cashflow_summary('2026-08-01', '2026-08-31')$q$, 'permission denied', '#28 anonymous visitors cannot call cashflow functions');
-- even an admin can't write to the tables directly
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select t.throws(format('update public.offline_orders set total = 1 where id = %s', t.id('off2')), 'permission denied', 'admins also go through the validated functions');
reset role;

-- ---------------------------------------------------------------- report
\o
select case when ok then 'PASS' else 'FAIL' end as result, name, case when ok then '' else info end as info from t.results order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.results;
do $$ begin
  if exists (select 1 from t.results where not ok) then raise exception 'SOME TESTS FAILED'; end if;
end $$;
