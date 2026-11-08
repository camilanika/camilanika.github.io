-- =====================================================================
-- Migration 018: order privacy and checkout limits (follow-up to the QA inspection of 8 Nov 2026)
-- Run after 017. Safe to run twice.
--
--   OBS-12   (part 1 of 2) admin_list_orders(): the admin page reads orders, including the admin-only
--            fields, through this function, which checks the admin role. Migration 019 then takes
--            those fields away from customers; run 019 only after the new admin.html is live.
--   DEF-002  The rest of DEF-002, enforced by create-payment through checkout_guard():
--            - a server-side switch for online payment (shop_settings.online_payment):
--              'off' = nobody, 'test' = admins only, 'on' = everyone
--            - per-network limits on checkout attempts (per hour and per day)
--            - a limit on unpaid orders per phone number held at the same time
--            Admins are never rate limited, so the owner can test.
--
-- Order of installation: 018 → merge the website (admin.html uses admin_list_orders) → paste create-payment → 019.
-- 018 only adds things, so the website and Edge Function that are live now keep working after it.
-- =====================================================================

-- ---------------------------------------------------------------- OBS-12: admin reads orders through an RPC
create or replace function public.admin_list_orders(
  p_statuses text[] default null,
  p_order_number text default null,
  p_order_id uuid default null,
  p_limit integer default 100)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  return coalesce((
    select jsonb_agg(
             to_jsonb(o) || jsonb_build_object('order_items', coalesce(
               (select jsonb_agg(to_jsonb(i) order by i.id) from public.order_items i where i.order_id = o.id), '[]'::jsonb))
             order by o.created_at desc)
    from (select * from public.orders x
           where (p_order_id is null or x.id = p_order_id)
             and (p_order_number is null or x.order_number = p_order_number)
             and (p_statuses is null or x.status = any (p_statuses))
           order by x.created_at desc
           limit least(greatest(coalesce(p_limit, 100), 1), 500)) o
  ), '[]'::jsonb);
end $$;
revoke execute on function public.admin_list_orders(text[], text, uuid, integer) from public, anon;
grant execute on function public.admin_list_orders(text[], text, uuid, integer) to authenticated;

-- ---------------------------------------------------------------- DEF-002: settings
alter table public.shop_settings
  add column if not exists online_payment text not null default 'test',
  add column if not exists checkout_limit_hour integer not null default 10,
  add column if not exists checkout_limit_day integer not null default 30,
  add column if not exists checkout_max_pending integer not null default 3;
alter table public.shop_settings drop constraint if exists shop_settings_online_payment_check;
alter table public.shop_settings add constraint shop_settings_online_payment_check
  check (online_payment in ('off', 'test', 'on'));
alter table public.shop_settings drop constraint if exists shop_settings_checkout_limits_check;
alter table public.shop_settings add constraint shop_settings_checkout_limits_check
  check (checkout_limit_hour >= 1 and checkout_limit_day >= 1 and checkout_max_pending >= 1);

-- ---------------------------------------------------------------- DEF-002: attempt log (server only)
create table if not exists public.checkout_log (
  id bigserial primary key,
  ip_hash text not null,
  phone text,
  user_id uuid,
  created_at timestamptz not null default now()
);
create index if not exists checkout_log_ip_time on public.checkout_log (ip_hash, created_at);
alter table public.checkout_log enable row level security;
revoke all on public.checkout_log from anon, authenticated;
revoke all on sequence public.checkout_log_id_seq from anon, authenticated;

-- same phone written as 0812…, +62 812… or 62812… counts as one number
create or replace function public.phone_key(p text) returns text language sql immutable as $$
  select regexp_replace(regexp_replace(coalesce(p, ''), '\D', '', 'g'), '^62', '0')
$$;

-- ---------------------------------------------------------------- DEF-002: the guard create-payment calls first
-- Returns {ok:true} or {ok:false, error: ONLINE_PAYMENT_OFF | RATE_LIMITED | TOO_MANY_PENDING}.
create or replace function public.checkout_guard(p_ip_hash text, p_phone text, p_user uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.shop_settings; v_admin boolean; v_phone text; h integer; d integer; p integer;
begin
  select * into s from public.shop_settings where id = 1;
  v_admin := p_user is not null and exists (select 1 from public.profiles where id = p_user and role = 'admin');

  if coalesce(s.online_payment, 'test') = 'off' or (coalesce(s.online_payment, 'test') = 'test' and not v_admin) then
    return jsonb_build_object('ok', false, 'error', 'ONLINE_PAYMENT_OFF');
  end if;
  if v_admin then return jsonb_build_object('ok', true); end if;

  -- one network at a time, so parallel requests can't slip past the count
  perform pg_advisory_xact_lock(hashtext('checkout_guard:' || coalesce(p_ip_hash, '')));

  select count(*) filter (where created_at > now() - interval '1 hour'), count(*) into h, d
    from public.checkout_log where ip_hash = p_ip_hash and created_at > now() - interval '1 day';
  if h >= s.checkout_limit_hour or d >= s.checkout_limit_day then
    return jsonb_build_object('ok', false, 'error', 'RATE_LIMITED');
  end if;

  v_phone := public.phone_key(p_phone);
  select count(*) into p from public.orders o
   where o.status = 'pending' and (o.expires_at is null or o.expires_at > now())
     and ((v_phone <> '' and public.phone_key(o.phone) = v_phone) or (p_user is not null and o.user_id = p_user));
  if p >= s.checkout_max_pending then
    return jsonb_build_object('ok', false, 'error', 'TOO_MANY_PENDING');
  end if;

  insert into public.checkout_log (ip_hash, phone, user_id) values (coalesce(p_ip_hash, 'unknown'), nullif(v_phone, ''), p_user);
  delete from public.checkout_log where created_at < now() - interval '30 days';
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.checkout_guard(text, text, uuid) from public, anon, authenticated;
grant execute on function public.checkout_guard(text, text, uuid) to service_role;
revoke execute on function public.phone_key(text) from public, anon, authenticated;
grant execute on function public.phone_key(text) to service_role;
