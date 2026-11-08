-- =====================================================================
-- Known defects: executable bug reports for the database (QA inspection, 8 Nov 2026)
-- Run with tests/db/known_defects.sh (npm run test:known-defects). It builds a fresh database from the repo.
-- Every check asserts the CORRECT behaviour, so it reports "STILL PRESENT" until the defect is fixed.
-- When a fix lands, its check turns "FIXED": move it into a regression file (qa_fixes_test.sql).
-- IDs match §4 of docs/test-cases-and-automation.docx. This script never fails the build.
-- Fixed by migration 017 and moved to qa_fixes_test.sql: DEF-002 (per-item cap), OBS-1, 2, 4, 6, 7, 8,
-- 14, 15, 16, 17, 19, 20, 21, 22. Fixed by migration 018 and moved to fixes_018_test.sql: OBS-12.
-- Open: OBS-36 (found in the QA re-run INSP-3, 8 Nov 2026).
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

-- (OBS-12 was fixed by migration 018 and moved to fixes_018_test.sql)

-- ---------------------------------------------------------------- OBS-36: re-running 010 / 011 undoes fixes from 017
-- known_defects.sh has just run migrations 010 and 011 again, as their headers say is safe.
select t.ok('OBS-36', position('15 minutes' in pg_get_functiondef('public.release_stale_voucher(bigint)'::regprocedure)) > 0,
            'after re-running 011, a voucher still stays with its order for the 15-minute grace (OBS-2)');
select t.ok('OBS-36', position('upper(trim(new.code)), ''''' in pg_get_functiondef('public.trg_code_unique()'::regprocedure)) > 0,
            'after re-running 011, promo codes are still stored trimmed and upper-case (OBS-15)');
select t.ok('OBS-36', position('30 menit' in pg_get_functiondef('public.trg_notify_order()'::regprocedure)) = 0,
            'after re-running 010, the order notification still gives the real payment deadline (OBS-17)');
select t.ok('OBS-36', position('promo_is_live(pr) then pr.code' in pg_get_functiondef('public.promo_details(bigint)'::regprocedure)) > 0,
            'after re-running 010, promo_details still hides the code of a promo that is not live (OBS-8)');

-- ---------------------------------------------------------------- report (never fails the build)
\o
select id, case when ok then 'FIXED' else 'STILL PRESENT' end as status, name, info from t.results order by n;
select count(*) filter (where not ok) as still_present, count(*) filter (where ok) as fixed from t.results;
