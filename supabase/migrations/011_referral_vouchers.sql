-- =====================================================================
-- Migration 011: referral campaigns, one-time vouchers, account badges
-- Safe to run on the live database (and safe to run twice).
--
-- referral_campaigns       admin-made codes shared on WhatsApp / Instagram ("JUNI2026")
-- referral_registrations   one row per account that signed up with a code (unique per account)
-- vouchers                 one-time codes, each owned by one customer (or unassigned until used)
--   status: pending (referral reward waiting for the first paid order) / available /
--           reserved (held by an unpaid order) / used / revoked.  "expired" = past expires_at.
-- voucher_events           history: created, assigned, reserved, released, used, revoked, activated
-- signup_log               sign-up attempts per (hashed) IP, for rate limits
--
-- Vouchers are typed in the same box as promo codes. The database checks ownership,
-- status, expiry, minimum and eligible products, holds the voucher while the order is
-- unpaid, marks it used when Midtrans confirms payment, and releases it if the payment
-- expires, fails or is cancelled.
-- =====================================================================
begin;

-- ---------------------------------------------------------------- settings / small changes
alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('product','promo','order','voucher','account'));

alter table public.shop_settings
  add column if not exists signup_limit_hour integer not null default 5 check (signup_limit_hour between 1 and 1000),
  add column if not exists signup_limit_day  integer not null default 20 check (signup_limit_day between 1 and 10000);

-- for a future WhatsApp OTP check; nothing sets it yet
alter table public.profiles add column if not exists phone_verified boolean not null default false;

create or replace function public.rp_text(n integer)
returns text language sql immutable as $$ select 'Rp' || replace(to_char(coalesce(n,0), 'FM999,999,999,999'), ',', '.') $$;

create or replace function public.offer_text(p_type text, p_value integer, p_min integer, p_max integer)
returns text language sql immutable as $$
  select case p_type when 'percent' then 'Diskon ' || p_value || '%' else 'Potongan ' || public.rp_text(p_value) end
      || case when p_type = 'percent' and p_max is not null then ' (maks. ' || public.rp_text(p_max) || ')' else '' end
      || case when coalesce(p_min, 0) > 0 then ', min. belanja ' || public.rp_text(p_min) else '' end;
$$;

-- ---------------------------------------------------------------- tables
create table if not exists public.referral_campaigns (
  id             bigint generated always as identity primary key,
  name           text not null,
  code           text not null unique check (code ~ '^[A-Z0-9-]{4,24}$'),
  status         text not null default 'active' check (status in ('active','paused','ended')),
  starts_at      timestamptz,
  ends_at        timestamptz,
  max_rewards    integer check (max_rewards > 0),          -- total vouchers this campaign may give
  daily_limit    integer check (daily_limit > 0),          -- vouchers per day (WIB)
  max_per_ip     integer not null default 3 check (max_per_ip > 0),  -- vouchers per network
  reward_on      text not null default 'signup' check (reward_on in ('signup','first_payment')),
  discount_type  text not null check (discount_type in ('percent','fixed')),
  value          integer not null check (value > 0),
  min_spend      integer not null default 0 check (min_spend >= 0),
  max_discount   integer check (max_discount > 0),
  applies_to_all boolean not null default true,
  valid_days     integer not null default 30 check (valid_days between 1 and 3650),
  note           text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (discount_type <> 'percent' or value between 1 and 100),
  check (ends_at is null or starts_at is null or ends_at > starts_at)
);
create table if not exists public.referral_campaign_products (
  campaign_id bigint not null references public.referral_campaigns(id) on delete cascade,
  product_id  bigint not null references public.products(id) on delete cascade,
  primary key (campaign_id, product_id)
);

create table if not exists public.vouchers (
  id                bigint generated always as identity primary key,
  code              text not null unique check (code ~ '^[A-Z0-9-]{4,24}$'),
  source            text not null check (source in ('referral','admin')),
  campaign_id       bigint references public.referral_campaigns(id) on delete set null,
  user_id           uuid references auth.users(id) on delete set null,   -- owner; null = not assigned yet
  discount_type     text not null check (discount_type in ('percent','fixed')),
  value             integer not null check (value > 0),
  min_spend         integer not null default 0 check (min_spend >= 0),
  max_discount      integer check (max_discount > 0),
  applies_to_all    boolean not null default true,
  expires_at        timestamptz,
  status            text not null default 'available' check (status in ('pending','available','reserved','used','revoked')),
  reserved_order_id uuid references public.orders(id) on delete set null,
  used_order_id     uuid references public.orders(id) on delete set null,
  used_at           timestamptz,
  revoked_at        timestamptz,
  assigned_at       timestamptz,
  assigned_by       uuid references auth.users(id) on delete set null,
  note              text,                          -- internal, admins only
  created_by        uuid references auth.users(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (discount_type <> 'percent' or value between 1 and 100)
);
create index if not exists vouchers_user_idx on public.vouchers (user_id);
-- one referral voucher per account per campaign, whatever happens
create unique index if not exists vouchers_one_referral on public.vouchers (campaign_id, user_id) where source = 'referral';

create table if not exists public.voucher_products (
  voucher_id bigint not null references public.vouchers(id) on delete cascade,
  product_id bigint not null references public.products(id) on delete cascade,
  primary key (voucher_id, product_id)
);

create table if not exists public.voucher_events (
  id         bigint generated always as identity primary key,
  voucher_id bigint not null references public.vouchers(id) on delete cascade,
  event      text not null check (event in ('created','assigned','reserved','released','used','revoked','activated')),
  order_id   uuid references public.orders(id) on delete set null,
  by_user    uuid references auth.users(id) on delete set null,
  note       text,
  created_at timestamptz not null default now()
);
create index if not exists voucher_events_idx on public.voucher_events (voucher_id, created_at);

create table if not exists public.referral_registrations (
  id          bigint generated always as identity primary key,
  campaign_id bigint not null references public.referral_campaigns(id) on delete cascade,
  user_id     uuid not null unique references auth.users(id) on delete cascade,   -- one per account
  voucher_id  bigint references public.vouchers(id) on delete set null,
  rewarded    boolean not null default false,
  reason      text,                 -- why no voucher (limit reached, ...)
  ip_hash     text,
  created_at  timestamptz not null default now()
);
create index if not exists referral_registrations_campaign_idx on public.referral_registrations (campaign_id, created_at);

create table if not exists public.signup_log (
  id         bigint generated always as identity primary key,
  ip_hash    text not null,
  phone      text,
  created_at timestamptz not null default now()
);
create index if not exists signup_log_ip_idx on public.signup_log (ip_hash, created_at);

alter table public.orders add column if not exists voucher_id bigint references public.vouchers(id) on delete set null;

-- updated_at
drop trigger if exists trg_referral_campaigns_updated on public.referral_campaigns;
create trigger trg_referral_campaigns_updated before update on public.referral_campaigns for each row execute function public.set_updated_at();
drop trigger if exists trg_vouchers_updated on public.vouchers;
create trigger trg_vouchers_updated before update on public.vouchers for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------- access
alter table public.referral_campaigns enable row level security;
alter table public.referral_campaign_products enable row level security;
alter table public.vouchers enable row level security;
alter table public.voucher_products enable row level security;
alter table public.voucher_events enable row level security;
alter table public.referral_registrations enable row level security;
alter table public.signup_log enable row level security;

drop policy if exists referral_campaigns_admin on public.referral_campaigns;
create policy referral_campaigns_admin on public.referral_campaigns for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists referral_campaign_products_admin on public.referral_campaign_products;
create policy referral_campaign_products_admin on public.referral_campaign_products for all to authenticated using (public.is_admin()) with check (public.is_admin());
-- vouchers & history: admins read directly; customers only through my_vouchers() (which hides internal notes)
drop policy if exists vouchers_admin_read on public.vouchers;
create policy vouchers_admin_read on public.vouchers for select to authenticated using (public.is_admin());
drop policy if exists voucher_products_admin_read on public.voucher_products;
create policy voucher_products_admin_read on public.voucher_products for select to authenticated using (public.is_admin());
drop policy if exists voucher_events_admin_read on public.voucher_events;
create policy voucher_events_admin_read on public.voucher_events for select to authenticated using (public.is_admin());
drop policy if exists referral_registrations_admin_read on public.referral_registrations;
create policy referral_registrations_admin_read on public.referral_registrations for select to authenticated using (public.is_admin());
revoke insert, update, delete on public.vouchers, public.voucher_products, public.voucher_events,
  public.referral_registrations, public.signup_log from anon, authenticated;
revoke all on public.signup_log from anon, authenticated;

-- a code means one thing: a voucher code can't also be a promo code or a referral code
create or replace function public.code_in_use(p_code text, p_except_table text, p_except_id bigint)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.promotions where upper(code) = upper(p_code) and not (p_except_table = 'promotions' and id = p_except_id))
      or exists (select 1 from public.vouchers where code = upper(p_code) and not (p_except_table = 'vouchers' and id = p_except_id))
      or exists (select 1 from public.referral_campaigns where code = upper(p_code) and not (p_except_table = 'referral_campaigns' and id = p_except_id));
$$;
create or replace function public.trg_code_unique()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name <> 'promotions' then new.code := upper(trim(new.code)); end if;
  if new.code is not null and public.code_in_use(new.code, tg_table_name, new.id) then
    raise exception 'CODE_TAKEN';
  end if;
  return new;
end $$;
drop trigger if exists trg_vouchers_code on public.vouchers;
create trigger trg_vouchers_code before insert or update of code on public.vouchers for each row execute function public.trg_code_unique();
drop trigger if exists trg_campaigns_code on public.referral_campaigns;
create trigger trg_campaigns_code before insert or update of code on public.referral_campaigns for each row execute function public.trg_code_unique();
drop trigger if exists trg_promotions_code on public.promotions;
create trigger trg_promotions_code before insert or update of code on public.promotions for each row execute function public.trg_code_unique();

-- ---------------------------------------------------------------- helpers
-- random code without look-alike characters (no 0/O, 1/I/L)
create or replace function public.gen_code(p_prefix text, p_len integer default 8)
returns text language plpgsql volatile security definer set search_path = public as $$
declare a text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; c text; i int;
begin
  loop
    c := '';
    for i in 1..p_len loop c := c || substr(a, 1 + floor(random() * length(a))::int, 1); end loop;
    if p_len >= 8 then c := substr(c, 1, 4) || '-' || substr(c, 5); end if;
    c := coalesce(nullif(p_prefix, '') || '-', '') || c;
    exit when not public.code_in_use(c, '', null);
  end loop;
  return c;
end $$;

-- status customers and admins see
create or replace function public.voucher_state(v public.vouchers)
returns text language sql stable as $$
  select case
    when v.status in ('used','revoked','reserved') then v.status
    when v.expires_at is not null and v.expires_at <= now() then 'expired'
    else v.status end;
$$;

-- a voucher held by an unpaid order whose 30 minutes are over is given back
create or replace function public.release_stale_voucher(p_voucher_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_num text;
begin
  select o.order_number into v_num
    from public.vouchers v join public.orders o on o.id = v.reserved_order_id
   where v.id = p_voucher_id and v.status = 'reserved' and o.status = 'pending' and o.expires_at < now();
  if v_num is not null then perform public.release_order(v_num, 'expired'); end if;
end $$;

create or replace function public.voucher_log(p_voucher bigint, p_event text, p_order uuid default null, p_note text default null)
returns void language sql security definer set search_path = public as $$
  insert into public.voucher_events (voucher_id, event, order_id, by_user, note) values (p_voucher, p_event, p_order, auth.uid(), p_note);
$$;

-- ---------------------------------------------------------------- checkout: promo OR voucher
-- quote_cart_v is the price calculator; p_user is who is buying (vouchers need an owner).
do $$
declare v_src text;
begin
  v_src := pg_get_functiondef('public.quote_cart(jsonb, text)'::regprocedure);
  if position('quote_cart_v' in v_src) = 0 then
    v_src := replace(v_src, 'FUNCTION public.quote_cart(p_items jsonb, p_promo_code text DEFAULT NULL::text)',
                            'FUNCTION public.quote_cart_v(p_items jsonb, p_promo_code text, p_user uuid)');
    -- voucher variables
    v_src := replace(v_src, '  v_code_ok   boolean := false;',
                            '  v_code_ok   boolean := false;
  v_vch       public.vouchers;
  v_vch_elig  integer;
  v_holder    public.orders;');
    -- before the final "code must have matched" check: apply a voucher if the code is one
    v_src := replace(v_src, '  if v_code is not null and not v_code_ok then
    raise exception ''PROMO_NOT_APPLICABLE'';
  end if;',
'  if v_code is not null and not v_code_ok then
    select * into v_vch from public.vouchers where code = v_code;
    if found then
      if p_user is null then raise exception ''VOUCHER_LOGIN_REQUIRED''; end if;
      if v_vch.user_id is not null and v_vch.user_id <> p_user then raise exception ''VOUCHER_NOT_YOURS''; end if;
      if v_vch.status = ''revoked'' then raise exception ''VOUCHER_REVOKED''; end if;
      if v_vch.status = ''used'' then raise exception ''VOUCHER_USED''; end if;
      if v_vch.status = ''pending'' then raise exception ''VOUCHER_PENDING''; end if;
      if v_vch.expires_at is not null and v_vch.expires_at <= now() then raise exception ''VOUCHER_EXPIRED''; end if;
      if v_vch.status = ''reserved'' then
        select * into v_holder from public.orders where id = v_vch.reserved_order_id;
        if v_holder.status = ''pending'' and v_holder.expires_at >= now() then
          raise exception ''VOUCHER_RESERVED:%'', v_holder.order_number;
        end if;
      end if;
      select coalesce(sum((l->>''line_total'')::int), 0) into v_vch_elig
        from jsonb_array_elements(v_lines) l
       where v_vch.applies_to_all
          or exists (select 1 from public.voucher_products vp
                      where vp.voucher_id = v_vch.id and vp.product_id = (l->>''product_id'')::bigint);
      if v_vch_elig = 0 then raise exception ''VOUCHER_NOT_APPLICABLE''; end if;
      if v_vch_elig < v_vch.min_spend then raise exception ''VOUCHER_MIN_SPEND:%'', v_vch.min_spend; end if;
      v_best_disc := case when v_vch.discount_type = ''percent''
                          then least(floor(v_vch_elig * v_vch.value / 100.0)::int, coalesce(v_vch.max_discount, 2147483647))
                          else least(v_vch.value, v_vch_elig) end;
      v_best := null;                   -- the voucher replaces automatic discounts (gifts still apply)
      v_code_ok := true;
    end if;
  end if;
  if v_code is not null and not v_code_ok then
    raise exception ''PROMO_NOT_APPLICABLE'';
  end if;');
    v_src := replace(v_src, '''promotion_id'', v_best.id, ''promo_name'', v_best.name, ''promo_code'', v_code,',
                            '''promotion_id'', v_best.id, ''promo_name'', coalesce(v_best.name, case when v_vch.id is not null then ''Voucher '' || v_vch.code end), ''promo_code'', v_code,
    ''voucher_id'', v_vch.id,');
    if position('VOUCHER_LOGIN_REQUIRED' in v_src) = 0 or position('''voucher_id'', v_vch.id' in v_src) = 0 then
      raise exception 'quote_cart patch failed';
    end if;
    execute v_src;
  end if;
end $$;

create or replace function public.quote_cart(p_items jsonb, p_promo_code text default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select public.quote_cart_v(p_items, p_promo_code, auth.uid());
$$;
revoke execute on function public.quote_cart_v(jsonb, text, uuid) from public, anon, authenticated;
grant execute on function public.quote_cart_v(jsonb, text, uuid) to service_role;
grant execute on function public.quote_cart(jsonb, text) to anon, authenticated;

-- create_order: price for the real buyer, then hold the voucher (atomic: one order wins)
do $$
declare v_src text;
begin
  v_src := pg_get_functiondef('public.create_order(uuid, jsonb, text, text, text, text, text, text, integer, double precision, double precision)'::regprocedure);
  if position('quote_cart_v' in v_src) = 0 then
    v_src := replace(v_src, 'v_quote := public.quote_cart(p_items, p_promo_code);',
                            'if nullif(trim(p_promo_code), '''') is not null then
    select id into v_vid from public.vouchers where code = upper(trim(p_promo_code));
    if v_vid is not null then perform public.release_stale_voucher(v_vid); end if;
  end if;
  v_quote := public.quote_cart_v(p_items, p_promo_code, p_user_id);');
    v_src := replace(v_src, '  v_number text;', '  v_number text;
  v_vid    bigint;');
    v_src := replace(v_src, '  returning * into v_order;',
'  returning * into v_order;

  if v_quote->>''voucher_id'' is not null then
    update public.vouchers
       set status = ''reserved'', reserved_order_id = v_order.id, user_id = coalesce(user_id, p_user_id)
     where id = (v_quote->>''voucher_id'')::bigint and status in (''available'', ''reserved'')
       and (status = ''available'' or reserved_order_id is null)
       and (user_id is null or user_id = p_user_id)
       and (expires_at is null or expires_at > now());
    if not found then raise exception ''VOUCHER_RESERVED''; end if;
    update public.orders set voucher_id = (v_quote->>''voucher_id'')::bigint where id = v_order.id;
    perform public.voucher_log((v_quote->>''voucher_id'')::bigint, ''reserved'', v_order.id, null);
  end if;');
    if position('VOUCHER_RESERVED' in v_src) = 0 or position('quote_cart_v' in v_src) = 0 then
      raise exception 'create_order patch failed';
    end if;
    execute v_src;
  end if;
end $$;

-- release_order (expired / failed / cancelled before payment): give the voucher back
do $$
declare v_src text;
begin
  v_src := pg_get_functiondef('public.release_order(text, text)'::regprocedure);
  if position('vouchers' in v_src) = 0 then
    v_src := replace(v_src, '  update public.orders set status = p_status where id = v_order.id;',
'  update public.orders set status = p_status where id = v_order.id;

  with r as (
    update public.vouchers
       set status = ''available'', reserved_order_id = null,
           user_id = case when source = ''admin'' and assigned_at is null then null else user_id end
     where reserved_order_id = v_order.id and status = ''reserved''
    returning id)
  insert into public.voucher_events (voucher_id, event, order_id, note)
    select id, ''released'', v_order.id, p_status from r;');
    if position('vouchers' in v_src) = 0 then raise exception 'release_order patch failed'; end if;
    execute v_src;
  end if;
end $$;

-- mark_order_paid: the voucher is used only once the payment is confirmed
do $$
declare v_src text;
begin
  v_src := pg_get_functiondef('public.mark_order_paid(text, text, text)'::regprocedure);
  if position('vouchers' in v_src) = 0 then
    v_src := replace(v_src, '  return ''paid'';',
'  if v_order.voucher_id is not null then
    with u as (
      update public.vouchers
         set status = ''used'', used_order_id = v_order.id, used_at = now(), reserved_order_id = null,
             user_id = coalesce(user_id, v_order.user_id)
       where id = v_order.voucher_id
         and (status = ''reserved'' and reserved_order_id = v_order.id
              or status = ''available'')         -- paid late, after the hold was released
      returning id)
    insert into public.voucher_events (voucher_id, event, order_id) select id, ''used'', v_order.id from u;
  end if;
  return ''paid'';');
    if position('vouchers' in v_src) = 0 then raise exception 'mark_order_paid patch failed'; end if;
    execute v_src;
  end if;
end $$;

-- referral rewards that wait for the first payment become usable then
create or replace function public.trg_activate_referral_voucher()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if new.user_id is null or new.status <> 'paid' or old.status = 'paid' then return null; end if;
  for r in
    update public.vouchers v
       set status = 'available', expires_at = now() + make_interval(days => coalesce(c.valid_days, 30))
      from public.referral_campaigns c
     where v.user_id = new.user_id and v.status = 'pending' and v.source = 'referral' and c.id = v.campaign_id
    returning v.id, v.code, v.discount_type, v.value, v.min_spend, v.max_discount
  loop
    insert into public.voucher_events (voucher_id, event, order_id, note) values (r.id, 'activated', new.id, 'first payment');
    insert into public.notifications (user_id, kind, title, body, link, ref_id, event_key)
      values (new.user_id, 'voucher', 'Voucher referral kamu sudah aktif',
              'Kode ' || r.code || ': ' || public.offer_text(r.discount_type, r.value, r.min_spend, r.max_discount) || '.',
              '#voucher', r.code, 'voucher:' || r.id || ':activated')
      on conflict (user_id, event_key) do nothing;
  end loop;
  return null;
end $$;
drop trigger if exists trg_orders_activate_referral on public.orders;
create trigger trg_orders_activate_referral after update of status on public.orders
  for each row execute function public.trg_activate_referral_voucher();

-- ---------------------------------------------------------------- referral sign-up (called by the phone-signup function)
create or replace function public.referral_preview(p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.referral_campaigns; v_given integer;
begin
  select * into c from public.referral_campaigns where code = upper(trim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('ok', false, 'error', 'REFERRAL_INVALID'); end if;
  if c.status = 'paused' then return jsonb_build_object('ok', false, 'error', 'REFERRAL_PAUSED'); end if;
  if c.status = 'ended' or (c.ends_at is not null and c.ends_at <= now()) then return jsonb_build_object('ok', false, 'error', 'REFERRAL_EXPIRED'); end if;
  if c.starts_at is not null and c.starts_at > now() then return jsonb_build_object('ok', false, 'error', 'REFERRAL_NOT_STARTED'); end if;
  select count(*) into v_given from public.referral_registrations where campaign_id = c.id and rewarded;
  if c.max_rewards is not null and v_given >= c.max_rewards then return jsonb_build_object('ok', false, 'error', 'REFERRAL_FULL'); end if;
  return jsonb_build_object('ok', true, 'name', c.name, 'reward', public.offer_text(c.discount_type, c.value, c.min_spend, c.max_discount),
    'reward_on', c.reward_on, 'valid_days', c.valid_days);
end $$;

-- rate limit: counts every sign-up attempt from the same (hashed) network
create or replace function public.signup_guard(p_ip_hash text, p_phone text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.shop_settings; h integer; d integer;
begin
  select * into s from public.shop_settings where id = 1;
  select count(*) filter (where created_at > now() - interval '1 hour'), count(*) into h, d
    from public.signup_log where ip_hash = p_ip_hash and created_at > now() - interval '1 day';
  if h >= s.signup_limit_hour or d >= s.signup_limit_day then
    return jsonb_build_object('ok', false, 'error', 'RATE_LIMITED');
  end if;
  insert into public.signup_log (ip_hash, phone) values (p_ip_hash, p_phone);
  delete from public.signup_log where created_at < now() - interval '30 days';
  return jsonb_build_object('ok', true);
end $$;

-- give the referral voucher (once per account; limits checked under a lock)
create or replace function public.referral_reward(p_user uuid, p_code text, p_ip_hash text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.referral_campaigns; pv jsonb; v_given int; v_today int; v_ip int; v_reason text; v public.vouchers;
begin
  select * into c from public.referral_campaigns where code = upper(trim(coalesce(p_code, ''))) for update;
  if not found then return jsonb_build_object('rewarded', false, 'reason', 'REFERRAL_INVALID'); end if;
  if exists (select 1 from public.referral_registrations where user_id = p_user) then
    return jsonb_build_object('rewarded', false, 'reason', 'ALREADY_REGISTERED');
  end if;
  pv := public.referral_preview(c.code);
  if not (pv->>'ok')::boolean then v_reason := pv->>'error'; end if;
  if v_reason is null then
    select count(*) filter (where created_at >= date_trunc('day', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta'),
           count(*) filter (where ip_hash = p_ip_hash)
      into v_today, v_ip
      from public.referral_registrations where campaign_id = c.id and rewarded;
    if c.daily_limit is not null and v_today >= c.daily_limit then v_reason := 'REFERRAL_DAILY_LIMIT';
    elsif p_ip_hash is not null and v_ip >= c.max_per_ip then v_reason := 'REFERRAL_DEVICE_LIMIT'; end if;
  end if;
  if v_reason is not null then
    insert into public.referral_registrations (campaign_id, user_id, rewarded, reason, ip_hash) values (c.id, p_user, false, v_reason, p_ip_hash);
    return jsonb_build_object('rewarded', false, 'reason', v_reason);
  end if;

  insert into public.vouchers (code, source, campaign_id, user_id, discount_type, value, min_spend, max_discount,
                               applies_to_all, expires_at, status, assigned_at)
  values (public.gen_code('REF'), 'referral', c.id, p_user, c.discount_type, c.value, c.min_spend, c.max_discount,
          c.applies_to_all,
          case when c.reward_on = 'signup' then now() + make_interval(days => c.valid_days) end,
          case when c.reward_on = 'signup' then 'available' else 'pending' end, now())
  returning * into v;
  insert into public.voucher_products (voucher_id, product_id) select v.id, product_id from public.referral_campaign_products where campaign_id = c.id;
  insert into public.referral_registrations (campaign_id, user_id, voucher_id, rewarded, ip_hash) values (c.id, p_user, v.id, true, p_ip_hash);
  insert into public.voucher_events (voucher_id, event, note) values (v.id, 'created', 'referral ' || c.code);
  insert into public.notifications (user_id, kind, title, body, link, ref_id, event_key)
    values (p_user, 'voucher',
            case when v.status = 'pending' then 'Voucher referral menunggu pesanan pertama' else 'Selamat! Kamu dapat voucher' end,
            'Kode ' || v.code || ': ' || public.offer_text(v.discount_type, v.value, v.min_spend, v.max_discount)
              || case when v.status = 'pending' then '. Aktif setelah pembayaran pertama kamu berhasil.' else '. Berlaku ' || c.valid_days || ' hari.' end,
            '#voucher', v.code, 'voucher:' || v.id || ':issued')
    on conflict (user_id, event_key) do nothing;
  return jsonb_build_object('rewarded', true, 'voucher', jsonb_build_object(
    'code', v.code, 'status', v.status, 'expires_at', v.expires_at,
    'offer', public.offer_text(v.discount_type, v.value, v.min_spend, v.max_discount), 'campaign', c.name));
end $$;

-- welcome message for every new account
create or replace function public.trg_welcome()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (user_id, kind, title, body, link, event_key)
    values (new.id, 'account', 'Selamat datang di CamilaNika!',
            'Akun kamu sudah aktif. Cek menu baru, promo, dan voucher kamu di sini.', '#voucher', 'account:welcome')
    on conflict (user_id, event_key) do nothing;
  return null;
end $$;
drop trigger if exists trg_profiles_welcome on public.profiles;
create trigger trg_profiles_welcome after insert on public.profiles for each row execute function public.trg_welcome();

-- ---------------------------------------------------------------- customer API
create or replace function public.voucher_json(v public.vouchers)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', v.id, 'code', v.code, 'source', v.source,
    'campaign', (select name from public.referral_campaigns where id = v.campaign_id),
    'discount_type', v.discount_type, 'value', v.value, 'min_spend', v.min_spend, 'max_discount', v.max_discount,
    'applies_to_all', v.applies_to_all,
    'products', coalesce((select jsonb_agg(p.name order by p.name) from public.voucher_products vp join public.products p on p.id = vp.product_id where vp.voucher_id = v.id), '[]'),
    'expires_at', v.expires_at, 'status', public.voucher_state(v),
    'reserved_order', (select order_number from public.orders where id = v.reserved_order_id),
    'used_order', (select order_number from public.orders where id = v.used_order_id),
    'used_at', v.used_at, 'created_at', v.created_at);
$$;
revoke execute on function public.voucher_json(public.vouchers) from public, anon, authenticated;

create or replace function public.my_vouchers()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); r record;
begin
  if v_uid is null then raise exception 'NOT_LOGGED_IN'; end if;
  for r in select id from public.vouchers where user_id = v_uid and status = 'reserved' loop
    perform public.release_stale_voucher(r.id);
  end loop;
  return jsonb_build_object(
    'referral', coalesce((select jsonb_agg(public.voucher_json(v) order by v.created_at desc) from public.vouchers v where v.user_id = v_uid and v.source = 'referral'), '[]'),
    'admin',    coalesce((select jsonb_agg(public.voucher_json(v) order by v.created_at desc) from public.vouchers v where v.user_id = v_uid and v.source = 'admin'), '[]'),
    'promos',   public.public_promotions());
end $$;

-- live promotions anyone can see (automatic ones, and code promos the admin chose to announce)
create or replace function public.public_promotions()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'name', pr.name, 'description', pr.description, 'code', pr.code,
      'discount_type', pr.discount_type, 'value', pr.value, 'gift_text', pr.gift_text, 'min_spend', pr.min_spend,
      'max_discount', pr.max_discount, 'starts_at', pr.starts_at, 'ends_at', pr.ends_at, 'applies_to_all', pr.applies_to_all,
      'products', coalesce((select jsonb_agg(p.name order by p.name) from public.promotion_products pp join public.products p on p.id = pp.product_id where pp.promotion_id = pr.id), '[]'))
    order by pr.ends_at nulls last, pr.id), '[]')
  from public.promotions pr
  where pr.is_active and (pr.code is null or pr.announce)
    and (pr.starts_at is null or pr.starts_at <= now()) and (pr.ends_at is null or pr.ends_at > now())
    and (pr.usage_limit is null or pr.used_count < pr.usage_limit);
$$;

-- red badges in "Akun saya"
create or replace function public.my_badges()
returns jsonb language sql stable security definer set search_path = public as $$
  with o as (select count(*)::int n from public.orders where user_id = auth.uid()
               and (status in ('paid','processing','ready','shipping') or (status = 'pending' and (expires_at is null or expires_at > now())))),
       nt as (select count(*)::int n from public.notifications where user_id = auth.uid() and read_at is null),
       vc as (select count(*)::int n from public.vouchers v where v.user_id = auth.uid() and public.voucher_state(v) = 'available')
  select jsonb_build_object('orders', o.n, 'notifications', nt.n, 'vouchers', vc.n, 'total', o.n + nt.n + vc.n) from o, nt, vc
  where auth.uid() is not null;
$$;

-- ---------------------------------------------------------------- admin API
create or replace function public.admin_find_customers(p_search text)
returns table (id uuid, full_name text, phone text, email text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare s text := trim(coalesce(p_search, '')); d text := regexp_replace(coalesce(p_search, ''), '\D', '', 'g');
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  if d like '62%' then d := substr(d, 3); elsif d like '0%' then d := substr(d, 2); end if;
  return query
  select p.id, p.full_name, p.phone, case when u.email like '%@phone.camilanika.invalid' then null else u.email::text end, p.created_at
    from public.profiles p join auth.users u on u.id = p.id
   where s = '' or p.id::text = s or p.full_name ilike '%' || s || '%' or u.email ilike '%' || s || '%'
      or (length(d) >= 4 and regexp_replace(coalesce(p.phone, '') || ' ' || u.email, '\D', '', 'g') like '%' || d || '%')
   order by p.created_at desc limit 20;
end $$;

create or replace function public.admin_create_voucher(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.vouchers; v_code text := upper(trim(coalesce(p->>'code', ''))); v_user uuid := nullif(p->>'user_id', '')::uuid;
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  if v_code = '' then v_code := public.gen_code('CN'); end if;
  if v_user is not null and not exists (select 1 from public.profiles where id = v_user) then raise exception 'CUSTOMER_NOT_FOUND'; end if;
  insert into public.vouchers (code, source, user_id, discount_type, value, min_spend, max_discount, applies_to_all,
                               expires_at, note, created_by, assigned_at, assigned_by)
  values (v_code, 'admin', v_user, p->>'discount_type', (p->>'value')::int, coalesce((p->>'min_spend')::int, 0),
          nullif(p->>'max_discount', '')::int, coalesce((p->>'applies_to_all')::boolean, true),
          nullif(p->>'expires_at', '')::timestamptz, nullif(trim(p->>'note'), ''), auth.uid(),
          case when v_user is not null then now() end, case when v_user is not null then auth.uid() end)
  returning * into v;
  insert into public.voucher_products (voucher_id, product_id)
    select v.id, x::bigint from jsonb_array_elements_text(coalesce(p->'product_ids', '[]')) x
    where not v.applies_to_all;
  perform public.voucher_log(v.id, 'created', null, null);
  if v_user is not null then perform public.admin_assign_notify(v); end if;
  return public.voucher_json(v) || jsonb_build_object('note', v.note);
end $$;

create or replace function public.admin_assign_notify(v public.vouchers)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.voucher_log(v.id, 'assigned', null, v.note);
  insert into public.notifications (user_id, kind, title, body, link, ref_id, event_key)
    values (v.user_id, 'voucher', 'Kamu dapat voucher dari CamilaNika',
            'Kode ' || v.code || ': ' || public.offer_text(v.discount_type, v.value, v.min_spend, v.max_discount)
              || case when v.expires_at is not null then ', berlaku sampai ' || to_char(v.expires_at at time zone 'Asia/Jakarta', 'DD/MM/YYYY') else '' end || '.',
            '#voucher', v.code, 'voucher:' || v.id || ':assigned:' || v.user_id)
    on conflict (user_id, event_key) do nothing;
end $$;
revoke execute on function public.admin_assign_notify(public.vouchers) from public, anon, authenticated;

create or replace function public.admin_assign_voucher(p_voucher_id bigint, p_user uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.vouchers;
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  if not exists (select 1 from public.profiles where id = p_user) then raise exception 'CUSTOMER_NOT_FOUND'; end if;
  select * into v from public.vouchers where id = p_voucher_id for update;
  if not found then raise exception 'VOUCHER_NOT_FOUND'; end if;
  if v.user_id is not null then raise exception 'VOUCHER_ALREADY_ASSIGNED'; end if;
  if public.voucher_state(v) <> 'available' then raise exception 'VOUCHER_NOT_AVAILABLE:%', public.voucher_state(v); end if;
  update public.vouchers set user_id = p_user, assigned_at = now(), assigned_by = auth.uid(),
         note = coalesce(nullif(trim(p_note), ''), note)
   where id = v.id returning * into v;
  perform public.admin_assign_notify(v);
  return public.voucher_json(v) || jsonb_build_object('note', v.note);
end $$;

create or replace function public.admin_revoke_voucher(p_voucher_id bigint, p_note text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v public.vouchers;
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  perform public.release_stale_voucher(p_voucher_id);
  select * into v from public.vouchers where id = p_voucher_id for update;
  if not found then raise exception 'VOUCHER_NOT_FOUND'; end if;
  if v.status = 'used' then raise exception 'VOUCHER_ALREADY_USED'; end if;
  if v.status = 'reserved' then raise exception 'VOUCHER_IN_USE'; end if;
  if v.status = 'revoked' then return 'revoked'; end if;
  update public.vouchers set status = 'revoked', revoked_at = now() where id = v.id;
  perform public.voucher_log(v.id, 'revoked', null, nullif(trim(p_note), ''));
  return 'revoked';
end $$;

create or replace function public.admin_list_vouchers(p_search text default null, p_state text default null, p_source text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  return coalesce((
    select jsonb_agg(x order by x->>'created_at' desc) from (
      select public.voucher_json(v) || jsonb_build_object('note', v.note, 'user_id', v.user_id,
               'owner_name', p.full_name, 'owner_phone', p.phone, 'assigned_at', v.assigned_at) x
        from public.vouchers v left join public.profiles p on p.id = v.user_id
       where (p_source is null or p_source = '' or v.source = p_source)
         and (p_state is null or p_state = '' or public.voucher_state(v) = p_state)
         and (p_search is null or trim(p_search) = '' or v.code ilike '%' || trim(p_search) || '%'
              or p.full_name ilike '%' || trim(p_search) || '%' or p.phone ilike '%' || trim(p_search) || '%')
       order by v.created_at desc limit 300) s), '[]');
end $$;

create or replace function public.admin_voucher_history(p_voucher_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('event', e.event, 'at', e.created_at, 'note', e.note,
            'order', o.order_number, 'order_status', o.status, 'by', p.full_name) order by e.created_at, e.id)
    from public.voucher_events e left join public.orders o on o.id = e.order_id left join public.profiles p on p.id = e.by_user
   where e.voucher_id = p_voucher_id), '[]');
end $$;

create or replace function public.admin_campaign_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  return coalesce((select jsonb_object_agg(c.id, jsonb_build_object(
      'registrations', (select count(*) from public.referral_registrations r where r.campaign_id = c.id),
      'issued', (select count(*) from public.vouchers v where v.campaign_id = c.id),
      'redeemed', (select count(*) from public.vouchers v where v.campaign_id = c.id and v.status = 'used')))
    from public.referral_campaigns c), '{}');
end $$;

create or replace function public.admin_campaign_registrations(p_campaign_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('name', p.full_name, 'phone', p.phone, 'at', r.created_at,
            'rewarded', r.rewarded, 'reason', r.reason, 'voucher', v.code, 'voucher_status', public.voucher_state(v),
            'used_order', (select order_number from public.orders where id = v.used_order_id)) order by r.created_at desc)
    from public.referral_registrations r left join public.profiles p on p.id = r.user_id left join public.vouchers v on v.id = r.voucher_id
   where r.campaign_id = p_campaign_id), '[]');
end $$;

-- ---------------------------------------------------------------- notifications: voucher & account items open the voucher page
create or replace function public.my_notifications(p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'NOT_LOGGED_IN'; end if;
  perform public.announce_due();
  return jsonb_build_object(
    'unread', (select count(*) from public.notifications where user_id = v_uid and read_at is null),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', n.id, 'kind', n.kind, 'title', n.title, 'body', n.body, 'link', n.link, 'ref_id', n.ref_id,
        'created_at', n.created_at, 'read', n.read_at is not null,
        'available', case n.kind
           when 'product' then public.product_on_sale(n.ref_id::bigint)
           when 'promo' then exists (select 1 from public.promotions pr where pr.id = n.ref_id::bigint and public.promo_is_live(pr))
           when 'order' then exists (select 1 from public.orders o where o.order_number = n.ref_id and o.user_id = v_uid)
           when 'voucher' then exists (select 1 from public.vouchers v where v.code = n.ref_id and v.user_id = v_uid)
           else true end)
        order by n.created_at desc, n.id desc)
      from (select * from public.notifications where user_id = v_uid
             order by created_at desc, id desc limit greatest(1, least(p_limit, 200))) n), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- grants
revoke execute on function public.gen_code(text, integer) from public, anon, authenticated;
revoke execute on function public.release_stale_voucher(bigint) from public, anon, authenticated;
revoke execute on function public.voucher_log(bigint, text, uuid, text) from public, anon, authenticated;
revoke execute on function public.signup_guard(text, text) from public, anon, authenticated;
revoke execute on function public.referral_reward(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.code_in_use(text, text, bigint) from public, anon, authenticated;
grant execute on function public.signup_guard(text, text) to service_role;
grant execute on function public.referral_reward(uuid, text, text) to service_role;
grant execute on function public.referral_preview(text) to anon, authenticated, service_role;
grant execute on function public.public_promotions() to anon, authenticated;
revoke execute on function public.my_vouchers() from public, anon;
revoke execute on function public.my_badges() from public, anon;
grant execute on function public.my_vouchers() to authenticated;
grant execute on function public.my_badges() to authenticated;
revoke execute on function public.admin_find_customers(text) from public, anon;
revoke execute on function public.admin_create_voucher(jsonb) from public, anon;
revoke execute on function public.admin_assign_voucher(bigint, uuid, text) from public, anon;
revoke execute on function public.admin_revoke_voucher(bigint, text) from public, anon;
revoke execute on function public.admin_list_vouchers(text, text, text) from public, anon;
revoke execute on function public.admin_voucher_history(bigint) from public, anon;
revoke execute on function public.admin_campaign_stats() from public, anon;
revoke execute on function public.admin_campaign_registrations(bigint) from public, anon;
grant execute on function public.admin_find_customers(text) to authenticated;
grant execute on function public.admin_create_voucher(jsonb) to authenticated;
grant execute on function public.admin_assign_voucher(bigint, uuid, text) to authenticated;
grant execute on function public.admin_revoke_voucher(bigint, text) to authenticated;
grant execute on function public.admin_list_vouchers(text, text, text) to authenticated;
grant execute on function public.admin_voucher_history(bigint) to authenticated;
grant execute on function public.admin_campaign_stats() to authenticated;
grant execute on function public.admin_campaign_registrations(bigint) to authenticated;

commit;
