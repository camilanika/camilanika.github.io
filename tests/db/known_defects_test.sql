-- =====================================================================
-- Known defects: executable bug reports for the database (QA inspection, 8 Nov 2026)
-- Run with tests/db/known_defects.sh (npm run test:known-defects). It builds a fresh database from the repo.
-- Every check asserts the CORRECT behaviour, so it reports "STILL PRESENT" until the defect is fixed.
-- When a fix lands, its check turns "FIXED": move it into a regression file (qa_fixes_test.sql).
-- IDs match §4 of docs/test-cases-and-automation.docx. This script never fails the build.
-- Fixed by migration 017 and moved to qa_fixes_test.sql: DEF-002 (per-item cap), OBS-1, 2, 4, 6, 7, 8,
-- 14, 15, 16, 17, 19, 20, 21, 22. Fixed by migration 018 and moved to fixes_018_test.sql: OBS-12.
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

-- (no open database defects: OBS-12 was fixed by migration 018 and moved to fixes_018_test.sql)

-- ---------------------------------------------------------------- report (never fails the build)
\o
select id, case when ok then 'FIXED' else 'STILL PRESENT' end as status, name, info from t.results order by n;
select count(*) filter (where not ok) as still_present, count(*) filter (where ok) as fixed from t.results;
