-- =====================================================================
-- Voucher policy (QA run INSP-5, 13 Nov 2026): what refund.html promises about vouchers matches the database.
-- refund.html (updated 13 Nov 2026): a voucher used on a paid order is not returned, also when the order is
-- cancelled; the admin can give a new voucher instead. Regression for OBS-39 (the page used to promise the voucher back).
-- Run with tests/db/run.sh (which also checks that refund.html still says this). Fails if any check fails.
-- =====================================================================
\set ON_ERROR_STOP 1
set client_min_messages = warning;
\o /dev/null

create schema t;
create table t.results (n serial primary key, id text not null, name text not null, ok boolean not null, info text);
create function t.ok(id text, c boolean, name text, info text default null) returns void language sql as $$
  insert into t.results (id, name, ok, info) values (id, name, coalesce(c, false), info) $$;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@test.local'),
  ('00000000-0000-0000-0000-00000000000c', 'customer@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-00000000000a';
update public.inventory set unlimited = true;
insert into public.vouchers (code, source, user_id, discount_type, value, status, expires_at) values
  ('QA-POLICY-PAID', 'admin', '00000000-0000-0000-0000-00000000000c', 'fixed', 5000, 'available', now() + interval '30 days'),
  ('QA-POLICY-UNPAID', 'admin', '00000000-0000-0000-0000-00000000000c', 'fixed', 5000, 'available', now() + interval '30 days');

do $$
declare paid text; unpaid text; c uuid := '00000000-0000-0000-0000-00000000000c';
begin
  paid := public.create_order(c, '[{"variant_id":1,"quantity":2}]', 'QA-POLICY-PAID', 'Tes', '081200000039')->>'order_number';
  perform public.mark_order_paid(paid);
  unpaid := public.create_order(c, '[{"variant_id":1,"quantity":2}]', 'QA-POLICY-UNPAID', 'Tes', '081200000040')->>'order_number';
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
  perform public.admin_set_order_status((select id from public.orders where order_number = paid), 'cancelled');
  perform public.admin_set_order_status((select id from public.orders where order_number = unpaid), 'cancelled');
  perform set_config('request.jwt.claim.sub', '', true);
  perform t.ok('OBS-39', (select status = 'used' from public.vouchers where code = 'QA-POLICY-PAID'),
               'a voucher used on a paid order stays used when the admin cancels the order (refund.html)',
               (select status from public.vouchers where code = 'QA-POLICY-PAID'));
  perform t.ok('OBS-39', (select status = 'available' from public.vouchers where code = 'QA-POLICY-UNPAID'),
               'a voucher held by an unpaid order is available again when that order is cancelled',
               (select status from public.vouchers where code = 'QA-POLICY-UNPAID'));
end $$;

\o
select id, case when ok then 'PASS' else 'FAIL' end as result, name, info from t.results order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.results;
do $$ begin if exists (select 1 from t.results where not ok) then raise exception 'voucher policy checks failed'; end if; end $$;
