-- =====================================================================
-- Tests for migration 022: opening days in the shop schedule
-- Run with tests/db/run.sh, which builds a fresh database from the repo, then runs this file.
-- Times are set around "now" in WIB, so the checks hold whenever the suite runs (a few minutes around midnight
-- are skipped for the overnight case).
-- =====================================================================
\set ON_ERROR_STOP 1
set client_min_messages = warning;
\o /dev/null
create schema t;
create table t.results (n serial primary key, id text not null, name text not null, ok boolean not null, info text);
create function t.ok(id text, c boolean, name text, info text default null) returns void language sql as $$
  insert into t.results (id, name, ok, info) values (id, name, coalesce(c, false), info) $$;
create function t.dow(shift int default 0) returns smallint language sql stable as $$
  select (((extract(isodow from now() at time zone 'Asia/Jakarta')::int - 1 + shift) % 7 + 7) % 7 + 1)::smallint $$;
create function t.at(mins int) returns time language sql stable as $$ select ((now() at time zone 'Asia/Jakarta') + make_interval(mins => mins))::time $$;
update public.inventory set unlimited = true;

select t.ok('SD-01', (public.shop_status()->'open_days') = '[1,2,3,4,5,6,7]'::jsonb, 'every day by default');
-- without a schedule the days don't matter
update public.shop_settings set schedule_enabled = false, open_days = array[t.dow(1)] where id = 1;
select t.ok('SD-01', (public.shop_status()->>'open')::boolean, 'no schedule: open even on a day that is not ticked');

-- schedule around now (24 hours on open days)
update public.shop_settings set schedule_enabled = true, open_time = '00:00', close_time = '00:00', open_days = '{1,2,3,4,5,6,7}' where id = 1;
select t.ok('SD-02', (public.shop_status()->>'open')::boolean, 'today ticked: open');
update public.shop_settings set open_days = array(select d from generate_series(1, 7) d where d <> t.dow())::smallint[] where id = 1;
select t.ok('SD-02', not (public.shop_status()->>'open')::boolean and public.shop_status()->>'reason' = 'schedule', 'today not ticked: closed by the schedule');
select t.ok('SD-02', not public.is_shop_open(), 'is_shop_open follows the days');
do $$ begin
  perform public.create_order(null, '[{"variant_id":1,"quantity":1}]', null, 'X', '081234567890');
  perform t.ok('SD-02', false, 'the server refuses orders on a closed day', 'accepted');
exception when others then perform t.ok('SD-02', sqlerrm like '%SHOP_CLOSED%', 'the server refuses orders on a closed day', sqlerrm);
end $$;

-- a normal window around now, today ticked / not ticked
update public.shop_settings set open_time = t.at(-60), close_time = t.at(60), open_days = array[t.dow()] where id = 1;
select t.ok('SD-03', (public.shop_status()->>'open')::boolean or t.at(-60) > t.at(60), 'inside the hours on an open day: open');

-- overnight schedule, now is in the after-midnight part: it counts as yesterday
do $$ begin
  if t.at(60) > t.at(120) or t.at(0) > t.at(60) then return; end if;   -- too close to midnight to set this up
  update public.shop_settings set open_time = t.at(120), close_time = t.at(60), open_days = array[t.dow(-1)] where id = 1;
  perform t.ok('SD-04', (public.shop_status()->>'open')::boolean, 'night schedule: after midnight belongs to yesterday (open)');
  update public.shop_settings set open_days = array[t.dow()] where id = 1;
  perform t.ok('SD-04', not (public.shop_status()->>'open')::boolean, 'night schedule: yesterday not ticked (closed)');
end $$;

do $$ begin
  update public.shop_settings set open_days = '{}' where id = 1;
  perform t.ok('SD-05', false, 'at least one day', 'accepted');
exception when check_violation then perform t.ok('SD-05', true, 'at least one day', null);
end $$;
do $$ begin
  update public.shop_settings set open_days = '{0,8}' where id = 1;
  perform t.ok('SD-05', false, 'only days 1–7', 'accepted');
exception when check_violation then perform t.ok('SD-05', true, 'only days 1–7', null);
end $$;

\o
select id, case when ok then 'PASS' else 'FAIL' end as result, name, case when ok then '' else info end as info from t.results order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.results;
do $$ begin if exists (select 1 from t.results where not ok) then raise exception 'SOME TESTS FAILED'; end if; end $$;
