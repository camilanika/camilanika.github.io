-- =====================================================================
-- Regression tests for migration 018: OBS-12 (order privacy) and the rest of DEF-002 (checkout guard)
-- Run with tests/db/run.sh, which builds a fresh database from the repo, then runs this file.
-- OBS-12 started as an executable bug report in known_defects_test.sql. The script fails if any check fails.
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
  ('00000000-0000-0000-0000-00000000000c', 'customer@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-00000000000a';
update public.inventory set unlimited = true;

create table t.ids as select public.create_order('00000000-0000-0000-0000-00000000000c', '[{"variant_id":1,"quantity":1}]', null, 'C', '081234567893')->>'order_number' as c_order_number;
grant select on t.ids to anon, authenticated;
update public.orders set classification_note = 'internal: customer is a chargeback risk', payment_issue = 'stock_resold'
 where order_number = (select c_order_number from t.ids);

-- ---------------------------------------------------------------- OBS-12 as the customer
create function t.as_customer() returns void language plpgsql as $$
declare v text; r record;
begin
  begin
    v := (select classification_note from public.orders where order_number = (select c_order_number from t.ids));
    perform t.ok('OBS-12', false, 'customers can''t read the admin''s internal classification note', 'customer read: ' || coalesce(v, 'NULL'));
  exception when insufficient_privilege then perform t.ok('OBS-12', true, 'customers can''t read the admin''s internal classification note', sqlerrm);
  end;
  begin
    v := (select payment_issue from public.orders where order_number = (select c_order_number from t.ids));
    perform t.ok('OBS-12', false, 'customers can''t read payment_issue', 'customer read: ' || coalesce(v, 'NULL'));
  exception when insufficient_privilege then perform t.ok('OBS-12', true, 'customers can''t read payment_issue', sqlerrm);
  end;
  -- every column the shop's "Pesanan saya" asks for (js/shop.js ORDER_COLS) still works
  begin
    select order_number, status, total, subtotal, discount, shipping_discount, promo_code, gifts, created_at, paid_at,
           expires_at, payment_method, customer_name, phone, address, notes, delivery_fee, delivery_km, delivery_lat,
           delivery_lng, snap_redirect_url, user_id
      into r from public.orders where user_id = auth.uid() and order_number = (select c_order_number from t.ids);
    perform t.ok('OBS-12', r.order_number is not null, 'customers still read every field the shop shows on their own orders', null);
  exception when others then perform t.ok('OBS-12', false, 'customers still read every field the shop shows on their own orders', sqlerrm);
  end;
  begin
    perform (select count(*) from public.order_items i where i.order_id = (select id from public.orders where order_number = (select c_order_number from t.ids)));
    perform t.ok('OBS-12', true, 'customers still read the lines of their own orders', null);
  exception when others then perform t.ok('OBS-12', false, 'customers still read the lines of their own orders', sqlerrm);
  end;
  begin
    perform public.admin_list_orders();
    perform t.ok('OBS-12', false, 'customers can''t call admin_list_orders', 'call succeeded');
  exception when others then perform t.ok('OBS-12', sqlerrm = 'NOT_ADMIN', 'customers can''t call admin_list_orders', sqlerrm);
  end;
  begin
    perform public.checkout_guard('x', '0812', auth.uid());
    perform t.ok('DEF-002', false, 'API users can''t call checkout_guard directly', 'call succeeded');
  exception when insufficient_privilege then perform t.ok('DEF-002', true, 'API users can''t call checkout_guard directly', sqlerrm);
  end;
end $$;
grant execute on function t.as_customer() to authenticated;
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
set local role authenticated;
select t.as_customer();
commit;

-- ---------------------------------------------------------------- OBS-12 as a guest
create function t.as_guest() returns void language plpgsql as $$
declare n int;
begin
  n := (select count(*) from public.orders);
  perform t.ok('OBS-12', n = 0, 'guests see no orders', n::text);
  begin
    perform (select max(classification_note) from public.orders);
    perform t.ok('OBS-12', false, 'guests can''t ask for admin-only order fields', 'select succeeded');
  exception when insufficient_privilege then perform t.ok('OBS-12', true, 'guests can''t ask for admin-only order fields', sqlerrm);
  end;
end $$;
grant execute on function t.as_guest() to anon;
begin;
set local role anon;
select t.as_guest();
commit;

-- ---------------------------------------------------------------- OBS-12 as the admin
create function t.as_admin() returns void language plpgsql as $$
declare j jsonb; o jsonb;
begin
  j := public.admin_list_orders(p_order_number => (select c_order_number from t.ids));
  o := j->0;
  perform t.ok('OBS-12', jsonb_array_length(j) = 1 and o->>'classification_note' = 'internal: customer is a chargeback risk'
                 and o->>'payment_issue' = 'stock_resold' and jsonb_array_length(o->'order_items') = 1,
               'the admin still sees internal fields and order lines through admin_list_orders', left(j::text, 200));
  j := public.admin_list_orders(p_order_id => (o->>'id')::uuid, p_limit => 1);
  perform t.ok('OBS-12', j->0->>'order_number' = o->>'order_number', 'admin_list_orders finds one order by id (Chat Customer)', null);
  j := public.admin_list_orders(p_statuses => array['completed']);
  perform t.ok('OBS-12', jsonb_array_length(j) = 0, 'admin_list_orders filters by status', j::text);
  j := public.admin_list_orders(p_statuses => array['pending']);
  perform t.ok('OBS-12', jsonb_array_length(j) >= 1, 'admin_list_orders lists pending orders', null);
end $$;
grant execute on function t.as_admin() to authenticated;
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
set local role authenticated;
select t.as_admin();
commit;

-- ---------------------------------------------------------------- DEF-002: online payment switch (runs as the server)
update public.shop_settings set online_payment = 'off' where id = 1;
select t.ok('DEF-002', (public.checkout_guard('ip-a', '081200000001', null)->>'error') = 'ONLINE_PAYMENT_OFF', 'online payment off: guests are refused', null);
select t.ok('DEF-002', (public.checkout_guard('ip-a', '081200000001', '00000000-0000-0000-0000-00000000000a')->>'error') = 'ONLINE_PAYMENT_OFF', 'online payment off: admins are refused too', null);
update public.shop_settings set online_payment = 'test' where id = 1;
select t.ok('DEF-002', (public.checkout_guard('ip-a', '081200000001', null)->>'error') = 'ONLINE_PAYMENT_OFF', 'test mode: guests are refused', null);
select t.ok('DEF-002', (public.checkout_guard('ip-a', '081200000001', '00000000-0000-0000-0000-00000000000c')->>'error') = 'ONLINE_PAYMENT_OFF', 'test mode: customers are refused', null);
select t.ok('DEF-002', (public.checkout_guard('ip-a', '081200000001', '00000000-0000-0000-0000-00000000000a')->>'ok')::boolean, 'test mode: admins can pay online', null);
select t.ok('DEF-002', (select default_value from (select column_default as default_value from information_schema.columns
  where table_schema = 'public' and table_name = 'shop_settings' and column_name = 'online_payment') x) like '''test''%',
  'a new install starts in test mode (matches ONLINE_PAYMENT: "test" in js/config.js)', null);

-- ---------------------------------------------------------------- DEF-002: per-network limits
update public.shop_settings set online_payment = 'on', checkout_limit_hour = 3, checkout_limit_day = 5, checkout_max_pending = 50 where id = 1;
do $$ declare i int; ok_count int := 0; last jsonb; begin
  for i in 1..4 loop
    last := public.checkout_guard('ip-b', '08130000000' || i, null);
    if (last->>'ok')::boolean then ok_count := ok_count + 1; end if;
  end loop;
  perform t.ok('DEF-002', ok_count = 3 and last->>'error' = 'RATE_LIMITED', 'the 4th attempt within an hour from one network is refused (limit 3)', ok_count || ' allowed, last ' || last::text);
  perform t.ok('DEF-002', (public.checkout_guard('ip-c', '081399999999', null)->>'ok')::boolean, 'another network is not affected', null);
  perform t.ok('DEF-002', (public.checkout_guard('ip-b', '081300000009', '00000000-0000-0000-0000-00000000000a')->>'ok')::boolean, 'admins are never rate limited', null);
  update public.checkout_log set created_at = now() - interval '2 hours' where ip_hash = 'ip-b';
  last := public.checkout_guard('ip-b', '081300000005', null);
  perform t.ok('DEF-002', (last->>'ok')::boolean, 'after an hour the network can order again (4th today)', last::text);
  last := public.checkout_guard('ip-b', '081300000006', null);
  last := public.checkout_guard('ip-b', '081300000007', null);
  perform t.ok('DEF-002', last->>'error' = 'RATE_LIMITED', 'the daily limit (5) still applies', last::text);
end $$;

-- ---------------------------------------------------------------- DEF-002: unpaid orders per phone
update public.shop_settings set checkout_limit_hour = 100, checkout_limit_day = 100, checkout_max_pending = 2 where id = 1;
do $$ declare last jsonb; begin
  perform public.create_order(null, '[{"variant_id":1,"quantity":1}]', null, 'P', '0857 1111 2222');
  perform public.create_order(null, '[{"variant_id":1,"quantity":1}]', null, 'P', '+62 857-1111-2222');
  last := public.checkout_guard('ip-d', '6285711112222', null);
  perform t.ok('DEF-002', last->>'error' = 'TOO_MANY_PENDING', 'a phone with 2 unpaid orders (any format) can''t start a 3rd', last::text);
  update public.orders set expires_at = now() - interval '1 minute' where public.phone_key(phone) = '085711112222';
  last := public.checkout_guard('ip-d', '085711112222', null);
  perform t.ok('DEF-002', (last->>'ok')::boolean, 'expired unpaid orders don''t count', last::text);
  last := public.checkout_guard('ip-d', '081234567893', '00000000-0000-0000-0000-00000000000c');
  perform t.ok('DEF-002', (last->>'ok')::boolean, 'one unpaid order is within the limit', last::text);
end $$;
update public.shop_settings set online_payment = 'test', checkout_limit_hour = 10, checkout_limit_day = 30, checkout_max_pending = 3 where id = 1;

-- ---------------------------------------------------------------- DEF-002: settings can't be set to nonsense
do $$ begin
  update public.shop_settings set online_payment = 'maybe' where id = 1;
  perform t.ok('DEF-002', false, 'online_payment only accepts off / test / on', 'accepted');
exception when check_violation then perform t.ok('DEF-002', true, 'online_payment only accepts off / test / on', null);
end $$;
do $$ begin
  update public.shop_settings set checkout_limit_hour = 0 where id = 1;
  perform t.ok('DEF-002', false, 'limits must be at least 1', 'accepted');
exception when check_violation then perform t.ok('DEF-002', true, 'limits must be at least 1', null);
end $$;

-- ---------------------------------------------------------------- migration 018 is safe to run twice (checked by run.sh)

-- ---------------------------------------------------------------- report
\o
select id, case when ok then 'PASS' else 'FAIL' end as result, name, case when ok then '' else info end as info from t.results order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.results;
do $$ begin
  if exists (select 1 from t.results where not ok) then raise exception 'SOME TESTS FAILED'; end if;
end $$;
