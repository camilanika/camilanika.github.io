-- =====================================================================
-- Security and money invariants: database regression tests
-- Run with tests/db/run.sh, which builds a fresh database from the repo, then runs this file.
-- Locks in what the QA inspection of 8 Nov 2026 found correct (docs/test-cases-and-automation.docx §1 DB area).
-- Each check writes a row to t.results; the script fails if any check fails.
-- =====================================================================
\set ON_ERROR_STOP 1
set client_min_messages = warning;
\o /dev/null

create schema t;
create table t.results (n serial primary key, name text not null, ok boolean not null, info text);
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
grant execute on all functions in schema t to anon, authenticated;

-- ---------------------------------------------------------------- fixtures
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@test.local'),
  ('00000000-0000-0000-0000-00000000000c', 'customer@test.local'),
  ('00000000-0000-0000-0000-00000000000d', 'other@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-00000000000a';
update public.inventory set unlimited = true;
create table t.o as select public.create_order('00000000-0000-0000-0000-00000000000d', '[{"variant_id":1,"quantity":1}]', null, 'Other', '081200000001') as o;
grant select on t.o to anon, authenticated;

-- ---------------------------------------------------------------- DB-01 schema hygiene
select t.eq((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity), 0,
            'DB-01 every public table has row level security on');
select t.eq((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.prosecdef
               and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')), 0,
            'DB-01 every SECURITY DEFINER function pins search_path');

-- ---------------------------------------------------------------- DB-02 internal functions are not callable by API users
select t.ok(not has_function_privilege(r, p.oid, 'execute'),
            format('DB-02 %s cannot execute %s', r, p.proname))
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace, unnest(array['anon', 'authenticated']) r
 where n.nspname = 'public' and p.proname in ('create_order', 'mark_order_paid', 'release_order', 'release_expired_orders',
       'quote_cart_v', 'tag_order_payment_env', 'notify_all', 'referral_reward', 'signup_guard');

-- ---------------------------------------------------------------- DB-03 every admin_* / cashflow_* RPC refuses a customer
create function t.not_admin_sweep() returns void language plpgsql as $$
declare p record; q text;
begin
  for p in select pr.oid, pr.proname, pr.pronargs from pg_proc pr join pg_namespace n on n.oid = pr.pronamespace
            where n.nspname = 'public' and (pr.proname like 'admin\_%' or pr.proname like 'cashflow\_%')
              and has_function_privilege('authenticated', pr.oid, 'execute') order by 2 loop
    q := format('select public.%I(%s)', p.proname, array_to_string(array_fill('null'::text, array[p.pronargs]), ', '));
    perform t.throws(q, 'NOT_ADMIN', 'DB-03 customer calling ' || p.proname || ' gets NOT_ADMIN');
  end loop;
end $$;
grant execute on function t.not_admin_sweep() to authenticated;
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
set local role authenticated;
select t.not_admin_sweep();
-- ---------------------------------------------------------------- DB-04 customers can't escalate or read others' data
select t.throws($$update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-00000000000c'$$, 'permission denied',
                'DB-04 customer cannot make themselves admin');
select t.throws($$update public.orders set status = 'paid', total = 1$$, 'permission denied', 'DB-04 customer cannot change orders');
select t.eq((select count(*)::int from public.orders), 0, 'DB-04 customer does not see another customer''s order');
select t.eq((select count(*)::int from public.profiles), 1, 'DB-04 customer sees only their own profile');
select t.eq((select count(*)::int from public.expenses) + (select count(*)::int from public.offline_orders), 0,
            'DB-04 customer sees no cashflow records');
commit;
begin;
set local role anon;
select t.eq((select count(*)::int from public.orders) + (select count(*)::int from public.profiles) + (select count(*)::int from public.promotions), 0,
            'DB-04 anonymous visitor sees no orders, profiles or promotions');
select t.eq(public.get_order_status((select o->>'order_number' from t.o), gen_random_uuid()), null::jsonb,
            'DB-04 order status needs the order''s secret access token');
select t.ok(public.get_order_status((select o->>'order_number' from t.o), (select (o->>'access_token')::uuid from t.o)) is not null,
            'DB-04 order status works with the right access token');
commit;

-- ---------------------------------------------------------------- DB-05 prices, quantities and payment are server-side
select t.eq((public.create_order(null, '[{"variant_id":1,"quantity":2,"price":1,"unit_price":1,"line_total":1}]', null, 'T', '081200000002')->>'total')::int,
            (public.quote_cart('[{"variant_id":1,"quantity":2}]')->>'total')::int,
            'DB-05 price fields sent by the client are ignored; the total is the server quote');
select t.throws($$select public.quote_cart('[{"variant_id":1,"quantity":0}]')$$, 'INVALID_QUANTITY', 'DB-05 quantity 0 is rejected');
select t.throws($$select public.quote_cart('[{"variant_id":1,"quantity":-1},{"variant_id":2,"quantity":3}]')$$, 'INVALID_QUANTITY', 'DB-05 a negative line is rejected');
select t.throws($$select public.quote_cart('[{"variant_id":1,"quantity":101}]')$$, 'INVALID_QUANTITY', 'DB-05 more than 100 on one line is rejected');
select t.throws($$select public.quote_cart('[]')$$, 'CART_EMPTY', 'DB-05 an empty cart is rejected');
do $$
declare n text := (select o->>'order_number' from t.o); before int;
begin
  perform public.mark_order_paid(n, 'ref-1', 'qris');
  before := (select count(*) from public.stock_movements);
  perform public.mark_order_paid(n, 'ref-1', 'qris');   -- the webhook arrives twice
  perform t.eq((select count(*)::int from public.stock_movements), before, 'DB-05 a repeated payment notification changes nothing');
  perform t.eq((select status from public.orders where order_number = n), 'paid', 'DB-05 order stays paid after a repeat');
  perform public.release_order(n, 'expired');           -- an "expired" notification after payment
  perform t.eq((select status from public.orders where order_number = n), 'paid', 'DB-05 a late expiry does not undo a payment');
end $$;

-- ---------------------------------------------------------------- report
\o
select case when ok then 'PASS' else 'FAIL' end as result, name, case when ok then '' else info end as info from t.results order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.results;
do $$ begin
  if exists (select 1 from t.results where not ok) then raise exception 'SOME TESTS FAILED'; end if;
end $$;
