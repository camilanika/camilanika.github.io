-- =====================================================================
-- Migration 022: opening days for the shop schedule
-- Safe to run on the live database (and safe to run twice).
--
-- shop_settings.open_days: the days the automatic schedule opens the shop (ISO weekday, 1 = Senin … 7 = Minggu),
-- every day by default. Only used while "Buka & tutup otomatis" (schedule_enabled) is on; without a schedule the
-- shop is open every day. A schedule that runs past midnight (e.g. 17:00–02:00) belongs to the day it opened,
-- so Saturday 01:00 counts as Friday's evening.
-- shop_status() (and with it is_shop_open(), the closed banner and the server's SHOP_CLOSED check) follows the days
-- and also returns them, so every page can show "Buka Senin–Sabtu · 10.00–20.00 WIB" or "Buka setiap hari".
-- =====================================================================
begin;

alter table public.shop_settings
  add column if not exists open_days smallint[] not null default '{1,2,3,4,5,6,7}';
alter table public.shop_settings drop constraint if exists shop_settings_open_days_check;
alter table public.shop_settings add constraint shop_settings_open_days_check
  check (cardinality(open_days) between 1 and 7 and open_days <@ '{1,2,3,4,5,6,7}'::smallint[]);

create or replace function public.shop_status()
returns jsonb language sql stable security definer set search_path = public as $$
  with s as (select * from public.shop_settings where id = 1),
       t as (select (now() at time zone 'Asia/Jakarta')::time as now_local,
                    extract(isodow from now() at time zone 'Asia/Jakarta')::int as dow),
       w as (   -- is the schedule open right now (time window and day)?
         select case
                  when s.open_time = s.close_time then t.dow = any(s.open_days)                       -- 24 hours on open days
                  when s.open_time < s.close_time then t.now_local >= s.open_time and t.now_local < s.close_time and t.dow = any(s.open_days)
                  when t.now_local >= s.open_time then t.dow = any(s.open_days)                       -- evening part of a night schedule
                  when t.now_local < s.close_time then ((t.dow + 5) % 7 + 1) = any(s.open_days)        -- after midnight: yesterday's opening
                  else false
                end as sched_open
           from s, t)
  select jsonb_build_object(
    'open', case when s.is_closed then false when not s.schedule_enabled then true else w.sched_open end,
    'reason', case when s.is_closed then 'closed' when s.schedule_enabled and not w.sched_open then 'schedule' else null end,
    'schedule_enabled', s.schedule_enabled,
    'open_time', to_char(s.open_time, 'HH24:MI'),
    'close_time', to_char(s.close_time, 'HH24:MI'),
    'open_days', to_jsonb(s.open_days),
    'today', t.dow,
    'message', s.closed_message,
    'now', to_char(t.now_local, 'HH24:MI'))
  from s, t, w;
$$;
revoke execute on function public.shop_status() from public;
grant execute on function public.shop_status() to anon, authenticated, service_role;

commit;
