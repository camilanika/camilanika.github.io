-- =====================================================================
-- Known defects: executable bug reports for the database (QA inspection, 8 Nov 2026)
-- Run with tests/db/known_defects.sh (npm run test:known-defects). It builds a fresh database from the repo.
-- Every check asserts the CORRECT behaviour, so it reports "STILL PRESENT" until the defect is fixed.
-- When a fix lands, its check turns "FIXED": move it into a regression file (qa_fixes_test.sql).
-- IDs match §4 of docs/test-cases-and-automation.docx. This script never fails the build.
-- Fixed by migration 017 and moved to qa_fixes_test.sql: DEF-002 (per-item cap), OBS-1, 2, 4, 6, 7, 8,
-- 14, 15, 16, 17, 19, 20, 21, 22.
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

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000c', 'customer@test.local');
update public.inventory set unlimited = true;

-- ---------------------------------------------------------------- OBS-12: admin-only note readable by the customer
-- Not fixed: admin.html reads orders with select("*") as the same "authenticated" role customers use, so a
-- column-level revoke would break the admin's own order list. Needs admin-only columns moved to their own table.
create table t.ids as select public.create_order('00000000-0000-0000-0000-00000000000c', '[{"variant_id":1,"quantity":1}]', null, 'C', '081234567893')->>'order_number' as c_order_number;
grant select on t.ids to authenticated;
update public.orders set classification_note = 'internal: customer is a chargeback risk' where order_number = (select c_order_number from t.ids);
create function t.read_note() returns void language plpgsql as $$
declare v text; begin
  v := (select classification_note from public.orders where order_number = (select c_order_number from t.ids));
  perform t.ok('OBS-12', false, 'customers can''t read the admin''s internal classification note', 'customer read: ' || coalesce(v, 'NULL'));
exception when others then perform t.ok('OBS-12', true, 'customers can''t read the admin''s internal classification note', sqlerrm);
end $$;
grant execute on function t.read_note() to authenticated;
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
set local role authenticated;
select t.read_note();
commit;

-- ---------------------------------------------------------------- report (never fails the build)
\o
select id, case when ok then 'FIXED' else 'STILL PRESENT' end as status, name, info from t.results order by n;
select count(*) filter (where not ok) as still_present, count(*) filter (where ok) as fixed from t.results;
