-- =====================================================================
-- Loyalty programme (migrations 012, 013): spending milestones give vouchers (QA re-run INSP-3, 8 Nov 2026)
-- Run with tests/db/run.sh, which builds a fresh database from the repo, then runs this file.
-- Catalogue cases PROMO-07 to PROMO-10 in docs/test-cases-and-automation.docx. Fails if any check fails.
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
  ('00000000-0000-0000-0000-0000000000c2', 'customer2@test.local'),
  ('00000000-0000-0000-0000-0000000000c3', 'customer3@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-00000000000a';
update public.inventory set unlimited = true;
delete from public.loyalty_tiers;
insert into public.loyalty_tiers (name, threshold, discount_type, value) values ('Silver', 25000, 'fixed', 5000);

-- an order of <qty> × variant 1 for a customer (null = guest), returns its number
create function t.order_for(p_user uuid, p_qty int) returns text language sql as $$
  select public.create_order(p_user, jsonb_build_array(jsonb_build_object('variant_id', 1, 'quantity', p_qty)), null, 'Tes', '0812' || floor(random() * 1e8)::text)->>'order_number' $$;
create function t.vouchers(p_user uuid, p_tier text) returns int language sql as $$
  select count(*)::int from public.vouchers v join public.loyalty_tiers x on x.id = v.tier_id
   where v.user_id = p_user and v.source = 'loyalty' and x.name = p_tier $$;
create table t.o (k text primary key, num text);
create function t.unit() returns int language sql as $$ select price from public.product_variants where id = 1 $$;

-- ---------------------------------------------------------------- PROMO-07: reaching a milestone gives one voucher
do $$
declare c uuid := '00000000-0000-0000-0000-00000000000c'; n int := ceil(12500.0 / t.unit())::int; a text; b text;
begin
  a := t.order_for(c, n); perform public.mark_order_paid(a);
  perform t.ok('PROMO-07', t.vouchers(c, 'Silver') = 0, 'below the milestone: no voucher yet', public.loyalty_spend(c)::text);
  b := t.order_for(c, n); perform public.mark_order_paid(b);
  insert into t.o values ('c-second', b);
  perform t.ok('PROMO-07', t.vouchers(c, 'Silver') = 1, 'the payment that crosses Rp25.000 gives exactly one Silver voucher',
               'spend ' || public.loyalty_spend(c) || ', vouchers ' || t.vouchers(c, 'Silver'));
  perform t.ok('PROMO-07', (select value = 5000 and status = 'available' and expires_at > now() + interval '29 days'
                              from public.vouchers where user_id = c and source = 'loyalty'),
               'the voucher is Rp5.000, available, valid 30 days', null);
  perform t.ok('PROMO-07', exists (select 1 from public.notifications where user_id = c and event_key like 'loyalty:%'),
               'the customer gets a "Hadiah loyalty" notification', null);
end $$;

-- ---------------------------------------------------------------- PROMO-08: repeats, refunds and re-crossing never pay twice
do $$
declare c uuid := '00000000-0000-0000-0000-00000000000c'; b text := (select num from t.o where k = 'c-second'); s1 int; d text;
begin
  perform public.mark_order_paid(b);   -- iPaymu notifies twice
  perform t.ok('PROMO-08', t.vouchers(c, 'Silver') = 1 and (select count(*) from public.loyalty_ledger where user_id = c and kind = 'earn') = 2,
               'a repeated payment notification counts the order once and gives no second voucher', null);
  s1 := public.loyalty_spend(c);
  update public.orders set status = 'cancelled' where order_number = b;   -- refunded
  perform t.ok('PROMO-08', public.loyalty_spend(c) = s1 - (select total from public.orders where order_number = b),
               'cancelling a paid order takes its amount off the total', s1 || ' -> ' || public.loyalty_spend(c));
  d := t.order_for(c, ceil(12500.0 / t.unit())::int); perform public.mark_order_paid(d);
  perform t.ok('PROMO-08', t.vouchers(c, 'Silver') = 1, 'crossing the same milestone again after a refund gives no second voucher',
               'vouchers ' || t.vouchers(c, 'Silver'));
end $$;

-- ---------------------------------------------------------------- PROMO-09: recurring tiers, guests
insert into public.loyalty_tiers (name, threshold, discount_type, value, recurring) values ('Tiap 50rb', 50000, 'fixed', 2000, true);
do $$
declare c2 uuid := '00000000-0000-0000-0000-0000000000c2'; g text; n int;
begin
  perform public.mark_order_paid(t.order_for(c2, ceil(100000.0 / t.unit())::int));   -- one payment past Rp100.000
  perform t.ok('PROMO-09', t.vouchers(c2, 'Tiap 50rb') = 2 and t.vouchers(c2, 'Silver') = 1,
               'one payment past two cycles of a recurring tier gives one voucher per cycle (and the Silver one)',
               'recurring ' || t.vouchers(c2, 'Tiap 50rb') || ', silver ' || t.vouchers(c2, 'Silver'));
  n := (select count(*) from public.loyalty_ledger);
  g := t.order_for(null, 10); perform public.mark_order_paid(g);
  perform t.ok('PROMO-09', (select count(*) from public.loyalty_ledger) = n, 'guest orders don''t count towards loyalty', null);
end $$;

-- ---------------------------------------------------------------- PROMO-10: delivery fee left out (unless the admin includes it)
do $$
declare c3 uuid := '00000000-0000-0000-0000-0000000000c3'; a text; amt int;
begin
  a := t.order_for(c3, 1);
  update public.orders set delivery_fee = 10000, shipping_discount = 4000, total = total + 6000 where order_number = a;
  perform public.mark_order_paid(a);
  amt := (select amount from public.loyalty_ledger l join public.orders o on o.id = l.order_id where o.order_number = a and l.kind = 'earn');
  perform t.ok('PROMO-10', amt = t.unit(), 'the ongkir the customer actually paid is not counted (fee 10.000 - shipping voucher 4.000)',
               'counted ' || amt || ', items ' || t.unit());
  update public.shop_settings set loyalty_include_shipping = true where id = 1;
  a := t.order_for(c3, 1);
  update public.orders set delivery_fee = 10000, total = total + 10000 where order_number = a;
  perform public.mark_order_paid(a);
  amt := (select amount from public.loyalty_ledger l join public.orders o on o.id = l.order_id where o.order_number = a and l.kind = 'earn');
  perform t.ok('PROMO-10', amt = t.unit() + 10000, 'with "include ongkir" switched on, the fee counts', 'counted ' || amt);
  update public.shop_settings set loyalty_include_shipping = false where id = 1;
end $$;

-- ---------------------------------------------------------------- permissions: customers can't give themselves rewards
create function t.as_customer() returns void language plpgsql as $$
begin
  begin
    insert into public.loyalty_ledger (user_id, order_id, kind, amount)
      select auth.uid(), id, 'earn', 1000000 from public.orders where user_id = auth.uid() limit 1;
    perform t.ok('PROMO-09', false, 'customers can''t add to their own loyalty total', 'insert accepted');
  exception when insufficient_privilege then perform t.ok('PROMO-09', true, 'customers can''t add to their own loyalty total', null);
  end;
  begin
    perform public.loyalty_check(auth.uid(), 0, 1000000, null);
    perform t.ok('PROMO-09', false, 'customers can''t call loyalty_check to trigger rewards', 'call succeeded');
  exception when insufficient_privilege then perform t.ok('PROMO-09', true, 'customers can''t call loyalty_check to trigger rewards', null);
  end;
  perform t.ok('PROMO-09', (public.my_loyalty()->>'spend') = (select num from t.o where k = 'c-spend'),
               'my_loyalty shows the customer''s own total', public.my_loyalty()->>'spend');
end $$;
grant execute on function t.as_customer() to authenticated;
grant select on t.o to authenticated;
insert into t.o values ('c-spend', public.loyalty_spend('00000000-0000-0000-0000-00000000000c')::text);
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
set local role authenticated;
select t.as_customer();
commit;

-- ---------------------------------------------------------------- report
\o
select id, case when ok then 'PASS' else 'FAIL' end as result, name, case when ok then '' else info end as info from t.results order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.results;
do $$ begin
  if exists (select 1 from t.results where not ok) then raise exception 'SOME TESTS FAILED'; end if;
end $$;
