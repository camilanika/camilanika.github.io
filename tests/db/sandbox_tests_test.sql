-- =====================================================================
-- Tests for migration 023: test (mock) payments through iPaymu Sandbox never turn into real rewards
-- Run with tests/db/run.sh, which builds a fresh database from the repo, then runs this file.
-- =====================================================================
\set ON_ERROR_STOP 1
set client_min_messages = warning;
\o /dev/null
create schema t;
create table t.results (n serial primary key, id text not null, name text not null, ok boolean not null, info text);
create function t.ok(id text, c boolean, name text, info text default null) returns void language sql as $$
  insert into t.results (id, name, ok, info) values (id, name, coalesce(c, false), info) $$;
insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000c', 'customer@test.local'),
                                          ('00000000-0000-0000-0000-0000000000c2', 'customer2@test.local');
update public.inventory set unlimited = true;
delete from public.loyalty_tiers;
insert into public.loyalty_tiers (name, threshold, discount_type, value) values ('Silver', 1000, 'fixed', 5000);
create function t.order_for(p_user uuid, p_env text) returns text language plpgsql as $$
declare n text;
begin
  n := public.create_order(p_user, '[{"variant_id":1,"quantity":1}]', null, 'Tes', '0812' || floor(random() * 1e8)::text)->>'order_number';
  perform public.tag_order_payment_env(n, p_env);
  return n;
end $$;

select t.ok('SB-01', (select sandbox_tests from public.shop_settings where id = 1), 'test payments are allowed by default');

-- a Sandbox payment: Mock order, no loyalty spending, no reward
do $$
declare c uuid := '00000000-0000-0000-0000-00000000000c'; a text;
begin
  a := t.order_for(c, 'sandbox'); perform public.mark_order_paid(a, 'trx', 'qris');
  perform t.ok('SB-02', (select classification = 'mock' and status = 'paid' from public.orders where order_number = a), 'Sandbox order is a paid Mock order', null);
  perform t.ok('SB-02', public.loyalty_spend(c) = 0, 'a Sandbox payment adds nothing to loyalty spending', public.loyalty_spend(c)::text);
  perform t.ok('SB-02', not exists (select 1 from public.vouchers where user_id = c and source = 'loyalty'), 'no loyalty voucher from a Sandbox payment', null);
end $$;

-- a real payment still counts
do $$
declare c uuid := '00000000-0000-0000-0000-0000000000c2'; a text;
begin
  a := t.order_for(c, 'production'); perform public.mark_order_paid(a, 'trx', 'qris');
  perform t.ok('SB-03', public.loyalty_spend(c) > 0, 'a real payment counts for loyalty', public.loyalty_spend(c)::text);
  perform t.ok('SB-03', exists (select 1 from public.vouchers where user_id = c and source = 'loyalty'), 'and gives the milestone voucher', null);
end $$;

-- a referral voucher waiting for the first payment stays waiting after a Sandbox payment
do $$
declare c uuid := '00000000-0000-0000-0000-00000000000c'; v bigint; camp bigint; a text;
begin
  insert into public.referral_campaigns (code, name, reward_on, discount_type, value) values ('SBXTEST', 'Tes', 'first_payment', 'fixed', 5000) returning id into camp;
  insert into public.vouchers (code, user_id, source, campaign_id, status, discount_type, value)
  values ('REF-SBX-0001', c, 'referral', camp, 'pending', 'fixed', 5000) returning id into v;
  a := t.order_for(c, 'sandbox'); perform public.mark_order_paid(a, 'trx', 'qris');
  perform t.ok('SB-04', (select status = 'pending' from public.vouchers where id = v), 'Sandbox payment does not activate a referral voucher', null);
  a := t.order_for(c, 'production'); perform public.mark_order_paid(a, 'trx', 'qris');
  perform t.ok('SB-04', (select status = 'available' from public.vouchers where id = v), 'a real first payment does', null);
end $$;

\o
select id, case when ok then 'PASS' else 'FAIL' end as result, name, case when ok then '' else info end as info from t.results order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.results;
do $$ begin if exists (select 1 from t.results where not ok) then raise exception 'SOME TESTS FAILED'; end if; end $$;
