-- =====================================================================
-- Tests for migration 021: series only (main menus internal), series texts, Semua texts, gallery, no GoFood
-- Run with tests/db/run.sh, which builds a fresh database from the repo, then runs this file.
-- =====================================================================
\set ON_ERROR_STOP 1
set client_min_messages = warning;
\o /dev/null
create schema t;
create table t.results (n serial primary key, id text not null, name text not null, ok boolean not null, info text);
create function t.ok(id text, c boolean, name text, info text default null) returns void language sql as $$
  insert into t.results (id, name, ok, info) values (id, name, coalesce(c, false), info) $$;
grant usage on schema t to anon, authenticated;
grant all on all tables in schema t to anon, authenticated;
grant all on all sequences in schema t to anon, authenticated;
grant execute on all functions in schema t to anon, authenticated;
insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000a', 'admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-00000000000a';

select t.ok('SG-01', (select count(*) = 0 from public.menu_sections where slug <> 'paket-hemat' and coalesce(description, '') = ''), 'every series has a description');
select t.ok('SG-01', (select array_length(highlights, 1) = 3 from public.menu_sections where slug = 'coffee'), 'coffee has its 3 info lines (extra shot, kulkas, es)');
select t.ok('SG-01', (select count(distinct sort_order) = count(*) from public.menu_sections where slug <> 'paket-hemat'), 'series have one order');
select t.ok('SG-01', not exists (select 1 from public.menu_categories where not is_active), 'all main menus are on (internal only)');

-- a new series typed in the admin page (no main menu) still works and shows up
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
set local role authenticated;
insert into public.menu_sections (name, slug, description, sort_order) values ('Seri Baru', 'seri-baru', 'Desc baru', 999);
commit;
select t.ok('SG-02', (select category_id is not null from public.menu_sections where slug = 'seri-baru'), 'a new series gets a main menu automatically');
select t.ok('SG-02', (select category_id <> (select id from public.menu_categories where slug = 'paket') from public.menu_sections where slug = 'seri-baru'), 'never the Paket Hemat one');

begin;
set local role anon;
select t.ok('SG-03', exists (select 1 from jsonb_array_elements(public.get_storefront()->'series') x where x->>'slug' = 'seri-baru' and x->>'description' = 'Desc baru'), 'storefront returns series texts');
select t.ok('SG-03', coalesce(public.get_storefront()->'menu'->>'intro', '') <> '', 'storefront returns the Semua description');
select t.ok('SG-03', jsonb_array_length(public.get_storefront()->'gallery') >= 2, 'gallery filled from the old photo showcases');
commit;

do $$ begin
  insert into public.testimonials (quote, source) values ('x', 'gofood');
  perform t.ok('SG-04', false, 'GoFood is no longer a testimonial source', 'accepted');
exception when check_violation then perform t.ok('SG-04', true, 'GoFood is no longer a testimonial source', null);
end $$;

\o
select id, case when ok then 'PASS' else 'FAIL' end as result, name, case when ok then '' else info end as info from t.results order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.results;
do $$ begin if exists (select 1 from t.results where not ok) then raise exception 'SOME TESTS FAILED'; end if; end $$;
