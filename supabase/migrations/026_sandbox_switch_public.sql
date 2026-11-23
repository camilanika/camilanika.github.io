-- =====================================================================
-- Migration 026: shop_status() tells the shop whether test payments (iPaymu Sandbox) are allowed
-- Safe to run on the live database (and safe to run twice). Needs migration 023.
--
-- With Admin → Toko → "Pembayaran tes" off, the shop ignores ?test=1: the test-mode banner goes away, the
-- address loses ?test=1, and payments go to live iPaymu as usual. shop_status() now returns sandbox_tests
-- so the shop can see the switch; everything else it returns is unchanged.
-- =====================================================================
begin;

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
    'now', to_char(t.now_local, 'HH24:MI'),
    'sandbox_tests', coalesce(s.sandbox_tests, true))
  from s, t, w;
$$;
revoke execute on function public.shop_status() from public;
grant execute on function public.shop_status() to anon, authenticated, service_role;

commit;
