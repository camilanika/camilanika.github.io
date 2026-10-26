-- =====================================================================
-- Migration 007: open / close the shop, with optional daily opening hours (WIB, GMT+7)
-- Safe to run on the live database (and safe to run twice).
--
-- shop_settings (one row)
--   is_closed         true  = closed until an admin opens it again (ignores the schedule)
--   schedule_enabled  true  = while not closed, only open between open_time and close_time
--   open_time/close_time  local time in Asia/Jakarta; close earlier than open = open past midnight
--   closed_message    optional text shown to customers while closed
-- shop_status()   what the shop page shows (anyone can call)
-- is_shop_open()  checked by create_order, so nobody can order while closed
-- =====================================================================
begin;

create table if not exists public.shop_settings (
  id                int primary key default 1 check (id = 1),
  is_closed         boolean not null default false,
  schedule_enabled  boolean not null default false,
  open_time         time not null default '08:00',
  close_time        time not null default '21:00',
  closed_message    text,
  updated_at        timestamptz not null default now()
);
insert into public.shop_settings (id) values (1) on conflict (id) do nothing;

drop trigger if exists trg_shop_settings_updated on public.shop_settings;
create trigger trg_shop_settings_updated before update on public.shop_settings
  for each row execute function public.set_updated_at();

alter table public.shop_settings enable row level security;
drop policy if exists shop_settings_admin on public.shop_settings;
create policy shop_settings_admin on public.shop_settings for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
revoke insert, delete on public.shop_settings from anon, authenticated;

create or replace function public.shop_status()
returns jsonb language sql stable security definer set search_path = public as $$
  with s as (select * from public.shop_settings where id = 1),
       t as (select (now() at time zone 'Asia/Jakarta')::time as now_local)
  select jsonb_build_object(
    'open', case
              when s.is_closed then false
              when not s.schedule_enabled then true
              when s.open_time = s.close_time then true
              when s.open_time < s.close_time then t.now_local >= s.open_time and t.now_local < s.close_time
              else t.now_local >= s.open_time or t.now_local < s.close_time
            end,
    'reason', case when s.is_closed then 'closed'
                   when s.schedule_enabled and s.open_time <> s.close_time and not (
                        case when s.open_time < s.close_time then t.now_local >= s.open_time and t.now_local < s.close_time
                             else t.now_local >= s.open_time or t.now_local < s.close_time end) then 'schedule'
                   else null end,
    'schedule_enabled', s.schedule_enabled,
    'open_time', to_char(s.open_time, 'HH24:MI'),
    'close_time', to_char(s.close_time, 'HH24:MI'),
    'message', s.closed_message,
    'now', to_char(t.now_local, 'HH24:MI'))
  from s, t;
$$;

create or replace function public.is_shop_open()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((public.shop_status()->>'open')::boolean, true);
$$;

revoke execute on function public.shop_status() from public;
grant execute on function public.shop_status() to anon, authenticated, service_role;
revoke execute on function public.is_shop_open() from public, anon, authenticated;
grant execute on function public.is_shop_open() to service_role;

-- Orders are refused while the shop is closed
do $$
declare v_src text;
begin
  v_src := pg_get_functiondef('public.create_order(uuid, jsonb, text, text, text, text, text, text, integer)'::regprocedure);
  if position('SHOP_CLOSED' in v_src) = 0 then
    v_src := replace(v_src,
      'if coalesce(trim(p_customer_name), '''') = '''' then raise exception ''NAME_REQUIRED''; end if;',
      'if not public.is_shop_open() then raise exception ''SHOP_CLOSED''; end if;
  if coalesce(trim(p_customer_name), '''') = '''' then raise exception ''NAME_REQUIRED''; end if;');
    if position('SHOP_CLOSED' in v_src) = 0 then raise exception 'create_order patch failed'; end if;
    execute v_src;
  end if;
end $$;

commit;
