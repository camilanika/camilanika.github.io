-- =====================================================================
-- Migration 012: loyalty program (automatic vouchers at spending milestones)
-- Safe to run on the live database (and safe to run twice).
--
-- loyalty_tiers    milestones set by the admin: "spend Rp250.000 in total -> Rp25.000 voucher".
--                  recurring = repeat every <threshold> (Rp500.000, Rp1.000.000, ...).
-- loyalty_ledger   one +amount row per paid order ('earn') and one -amount row if a paid order is
--                  later cancelled/refunded ('reverse'). Unique per order, so repeated Midtrans
--                  callbacks never count twice. A customer's spending = sum of their rows.
-- loyalty_rewards  one row per customer + tier (+ cycle for recurring tiers): the voucher given.
--                  Unique, so a milestone is never rewarded twice.
--
-- Rules
--  * Counted: orders with an account that reach paid / processing / ready / shipping / completed.
--    Amount = order total after discounts, without delivery fee (unless the admin includes it).
--  * A reward is given when a payment takes the customer's total from below a threshold to at
--    or above it. Customers already above a newly created or lowered threshold are NOT rewarded
--    automatically; the admin can do that on purpose with "give to customers who qualify".
--  * Cancelling a paid order (refund) removes its amount. Vouchers already earned are kept
--    (the admin can revoke one by hand); reaching the milestone again never gives a second one.
--  * Orders paid before this migration count toward the total, without giving rewards.
-- =====================================================================
begin;

-- ---------------------------------------------------------------- settings & tables
alter table public.shop_settings add column if not exists loyalty_include_shipping boolean not null default false;

create table if not exists public.loyalty_tiers (
  id            bigint generated always as identity primary key,
  name          text not null,
  threshold     integer not null check (threshold > 0),
  discount_type text not null check (discount_type in ('percent','fixed')),
  value         integer not null check (value > 0),
  max_discount  integer check (max_discount > 0),
  min_spend     integer not null default 0 check (min_spend >= 0),
  valid_days    integer not null default 30 check (valid_days between 1 and 3650),
  valid_until   timestamptz,                        -- optional fixed last day for vouchers from this tier
  description   text,                               -- shown to customers
  recurring     boolean not null default false,     -- every <threshold> again
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (discount_type <> 'percent' or value between 1 and 100)
);
drop trigger if exists trg_loyalty_tiers_updated on public.loyalty_tiers;
create trigger trg_loyalty_tiers_updated before update on public.loyalty_tiers for each row execute function public.set_updated_at();

create table if not exists public.loyalty_ledger (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  order_id   uuid not null references public.orders(id) on delete cascade,
  kind       text not null check (kind in ('earn','reverse')),
  amount     integer not null,
  created_at timestamptz not null default now(),
  unique (order_id, kind)
);
create index if not exists loyalty_ledger_user_idx on public.loyalty_ledger (user_id, created_at);

alter table public.vouchers drop constraint if exists vouchers_source_check;
alter table public.vouchers add constraint vouchers_source_check check (source in ('referral','admin','loyalty'));
alter table public.vouchers add column if not exists tier_id bigint references public.loyalty_tiers(id) on delete set null;

create table if not exists public.loyalty_rewards (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  tier_id      bigint not null references public.loyalty_tiers(id) on delete cascade,
  cycle        integer not null default 1,
  voucher_id   bigint references public.vouchers(id) on delete set null,
  spend_at     integer not null,              -- customer's total when it was given
  order_id     uuid references public.orders(id) on delete set null,
  granted_by   uuid references auth.users(id) on delete set null,   -- set when an admin gave it on purpose
  created_at   timestamptz not null default now(),
  unique (user_id, tier_id, cycle)
);

alter table public.loyalty_tiers enable row level security;
alter table public.loyalty_ledger enable row level security;
alter table public.loyalty_rewards enable row level security;
drop policy if exists loyalty_tiers_admin on public.loyalty_tiers;
create policy loyalty_tiers_admin on public.loyalty_tiers for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists loyalty_ledger_admin on public.loyalty_ledger;
create policy loyalty_ledger_admin on public.loyalty_ledger for select to authenticated using (public.is_admin());
drop policy if exists loyalty_rewards_admin on public.loyalty_rewards;
create policy loyalty_rewards_admin on public.loyalty_rewards for select to authenticated using (public.is_admin());
revoke insert, update, delete on public.loyalty_ledger, public.loyalty_rewards from anon, authenticated;

-- ---------------------------------------------------------------- helpers
create or replace function public.loyalty_spend(p_user uuid)
returns integer language sql stable security definer set search_path = public as $$
  select coalesce(sum(amount), 0)::int from public.loyalty_ledger where user_id = p_user;
$$;

create or replace function public.loyalty_amount(o public.orders)
returns integer language sql stable security definer set search_path = public as $$
  select greatest(o.total - case when (select loyalty_include_shipping from public.shop_settings where id = 1)
                                 then 0 else coalesce(o.delivery_fee, 0) end, 0);
$$;

create or replace function public.tier_reward_text(t public.loyalty_tiers)
returns text language sql immutable as $$
  select 'voucher ' || case when t.discount_type = 'percent' then t.value || '%' else public.rp_text(t.value) end;
$$;

-- give one tier reward (cycle) to a customer: voucher + notification. Does nothing if already given.
create or replace function public.loyalty_issue(p_user uuid, t public.loyalty_tiers, p_cycle integer, p_spend integer, p_order uuid, p_by uuid default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_reward bigint; v public.vouchers;
begin
  insert into public.loyalty_rewards (user_id, tier_id, cycle, spend_at, order_id, granted_by)
    values (p_user, t.id, p_cycle, p_spend, p_order, p_by)
    on conflict (user_id, tier_id, cycle) do nothing
    returning id into v_reward;
  if v_reward is null then return null; end if;     -- already rewarded
  insert into public.vouchers (code, source, tier_id, user_id, discount_type, value, min_spend, max_discount,
                               applies_to_all, expires_at, status, assigned_at, note)
  values (public.gen_code('LOY'), 'loyalty', t.id, p_user, t.discount_type, t.value, t.min_spend,
          case when t.discount_type = 'percent' then t.max_discount end, true,
          case when t.valid_until is null then now() + make_interval(days => t.valid_days)
               else least(now() + make_interval(days => t.valid_days), t.valid_until) end,
          'available', now(), 'loyalty: ' || t.name || case when p_cycle > 1 then ' #' || p_cycle else '' end)
  returning * into v;
  update public.loyalty_rewards set voucher_id = v.id where id = v_reward;
  insert into public.voucher_events (voucher_id, event, order_id, by_user, note)
    values (v.id, 'created', p_order, p_by, 'loyalty ' || t.name || ' (' || public.rp_text(t.threshold) || ')');
  insert into public.notifications (user_id, kind, title, body, link, ref_id, event_key)
    values (p_user, 'voucher', 'Hadiah loyalty terbuka! 🎉',
            'Total belanja kamu sudah ' || public.rp_text(p_spend) || '. Kamu dapat ' || public.tier_reward_text(t)
              || ' (kode ' || v.code || ')' || case when t.min_spend > 0 then ', min. belanja ' || public.rp_text(t.min_spend) else '' end
              || ', berlaku sampai ' || to_char(v.expires_at at time zone 'Asia/Jakarta', 'DD/MM/YYYY') || '.',
            '#loyalty', v.code, 'loyalty:' || t.id || ':' || p_cycle)
    on conflict (user_id, event_key) do nothing;
  return v.id;
end $$;

-- the next milestone for a customer with this total (non-recurring not yet reached, or the next cycle)
create or replace function public.loyalty_next(p_user uuid, p_spend integer)
returns table (tier_id bigint, threshold integer, cycle integer)
language sql stable security definer set search_path = public as $$
  select id, th, cyc from (
    select t.id, t.threshold as th, 1 as cyc from public.loyalty_tiers t
     where t.is_active and not t.recurring and t.threshold > p_spend
       and not exists (select 1 from public.loyalty_rewards r where r.user_id = p_user and r.tier_id = t.id)
    union all
    select t.id, (floor(p_spend::numeric / t.threshold)::int + 1) * t.threshold, floor(p_spend::numeric / t.threshold)::int + 1
      from public.loyalty_tiers t where t.is_active and t.recurring
  ) x order by th, id limit 1;
$$;

-- after a payment took the customer's total from p_before to p_after
create or replace function public.loyalty_check(p_user uuid, p_before integer, p_after integer, p_order uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.loyalty_tiers; c integer; nx record;
begin
  for t in select * from public.loyalty_tiers where is_active order by threshold loop
    if t.recurring then
      for c in (floor(p_before::numeric / t.threshold)::int + 1) .. floor(p_after::numeric / t.threshold)::int loop
        perform public.loyalty_issue(p_user, t, c, p_after, p_order);
      end loop;
    elsif p_before < t.threshold and p_after >= t.threshold then
      perform public.loyalty_issue(p_user, t, 1, p_after, p_order);
    end if;
  end loop;
  -- close to the next reward (80% of the way): a one-time nudge
  select * into nx from public.loyalty_next(p_user, p_after);
  if nx.tier_id is not null and p_after >= nx.threshold * 0.8 then
    select * into t from public.loyalty_tiers where id = nx.tier_id;
    insert into public.notifications (user_id, kind, title, body, link, ref_id, event_key)
      values (p_user, 'voucher', 'Sedikit lagi dapat hadiah!',
              'Belanja ' || public.rp_text(nx.threshold - p_after) || ' lagi untuk dapat ' || public.tier_reward_text(t) || '.',
              '#loyalty', null, 'loyalty-near:' || t.id || ':' || nx.cycle)
      on conflict (user_id, event_key) do nothing;
  end if;
end $$;

-- ---------------------------------------------------------------- order trigger: count payments, reverse refunds
create or replace function public.trg_loyalty_order()
returns trigger language plpgsql security definer set search_path = public as $$
declare counted text[] := array['paid','processing','ready','shipping','completed'];
        v_before integer; v_amt integer; v_earned integer;
begin
  if new.user_id is null or new.status is not distinct from old.status then return null; end if;
  -- one customer at a time, so two payments arriving together can't both miss (or both hit) a milestone
  perform pg_advisory_xact_lock(hashtext('loyalty:' || new.user_id::text));
  if new.status = any(counted) and not (old.status = any(counted)) then
    v_before := public.loyalty_spend(new.user_id);
    v_amt := public.loyalty_amount(new);
    insert into public.loyalty_ledger (user_id, order_id, kind, amount) values (new.user_id, new.id, 'earn', v_amt)
      on conflict (order_id, kind) do nothing;
    if found and v_amt > 0 then perform public.loyalty_check(new.user_id, v_before, v_before + v_amt, new.id); end if;
  elsif new.status in ('cancelled','failed','expired') and old.status = any(counted) then
    select amount into v_earned from public.loyalty_ledger where order_id = new.id and kind = 'earn';
    if v_earned is not null then
      insert into public.loyalty_ledger (user_id, order_id, kind, amount) values (new.user_id, new.id, 'reverse', -v_earned)
        on conflict (order_id, kind) do nothing;
    end if;
  end if;
  return null;
end $$;
drop trigger if exists trg_orders_loyalty on public.orders;
create trigger trg_orders_loyalty after update of status on public.orders
  for each row execute function public.trg_loyalty_order();

-- past paid orders count toward the total (no rewards for them)
insert into public.loyalty_ledger (user_id, order_id, kind, amount, created_at)
  select o.user_id, o.id, 'earn', public.loyalty_amount(o), coalesce(o.paid_at, o.created_at)
    from public.orders o
   where o.user_id is not null and o.status in ('paid','processing','ready','shipping','completed')
  on conflict (order_id, kind) do nothing;
insert into public.loyalty_ledger (user_id, order_id, kind, amount, created_at)
  select o.user_id, o.id, 'reverse', -public.loyalty_amount(o), o.updated_at
    from public.orders o
   where o.user_id is not null and o.status = 'cancelled' and o.paid_at is not null
  on conflict (order_id, kind) do nothing;

-- ---------------------------------------------------------------- vouchers: show the tier, list loyalty vouchers
create or replace function public.voucher_json(v public.vouchers)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', v.id, 'code', v.code, 'source', v.source,
    'campaign', (select name from public.referral_campaigns where id = v.campaign_id),
    'tier', (select name from public.loyalty_tiers where id = v.tier_id),
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
    'loyalty',  coalesce((select jsonb_agg(public.voucher_json(v) order by v.created_at desc) from public.vouchers v where v.user_id = v_uid and v.source = 'loyalty'), '[]'),
    'admin',    coalesce((select jsonb_agg(public.voucher_json(v) order by v.created_at desc) from public.vouchers v where v.user_id = v_uid and v.source = 'admin'), '[]'),
    'promos',   public.public_promotions());
end $$;

-- ---------------------------------------------------------------- customer: loyalty dashboard
create or replace function public.my_loyalty()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_spend integer; nx record; t public.loyalty_tiers; v_prev integer;
begin
  if v_uid is null then raise exception 'NOT_LOGGED_IN'; end if;
  v_spend := public.loyalty_spend(v_uid);
  select * into nx from public.loyalty_next(v_uid, v_spend);
  if nx.tier_id is not null then select * into t from public.loyalty_tiers where id = nx.tier_id; end if;
  return jsonb_build_object(
    'enabled', exists (select 1 from public.loyalty_tiers where is_active),
    'spend', v_spend,
    'include_shipping', (select loyalty_include_shipping from public.shop_settings where id = 1),
    'tiers', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'threshold', x.threshold,
               'reward', public.tier_reward_text(x), 'discount_type', x.discount_type, 'value', x.value,
               'min_spend', x.min_spend, 'max_discount', x.max_discount, 'valid_days', x.valid_days,
               'description', x.description, 'recurring', x.recurring,
               'times', (select count(*) from public.loyalty_rewards r where r.user_id = v_uid and r.tier_id = x.id))
             order by x.threshold, x.id) from public.loyalty_tiers x where x.is_active), '[]'),
    'highest', (select jsonb_build_object('name', x.name, 'threshold', x.threshold * r.cycle, 'reward', public.tier_reward_text(x))
                  from public.loyalty_rewards r join public.loyalty_tiers x on x.id = r.tier_id
                 where r.user_id = v_uid order by x.threshold * r.cycle desc, r.id desc limit 1),
    'next', case when nx.tier_id is null then null else jsonb_build_object(
               'tier_id', t.id, 'name', t.name, 'threshold', nx.threshold, 'cycle', nx.cycle,
               'remaining', nx.threshold - v_spend, 'percent', least(100, floor(v_spend * 100.0 / nx.threshold))::int,
               'reward', public.tier_reward_text(t), 'min_spend', t.min_spend, 'description', t.description) end,
    'vouchers', coalesce((select jsonb_agg(public.voucher_json(v) order by v.created_at desc)
                  from public.vouchers v where v.user_id = v_uid and v.source = 'loyalty'), '[]'),
    'history', coalesce((select jsonb_agg(jsonb_build_object('kind', l.kind, 'amount', l.amount, 'at', l.created_at, 'order', o.order_number)
                  order by l.created_at desc, l.id desc) from (select * from public.loyalty_ledger where user_id = v_uid order by created_at desc, id desc limit 30) l
                  left join public.orders o on o.id = l.order_id), '[]'));
end $$;

-- vouchers about to expire: one reminder each (called when the customer opens notifications)
create or replace function public.remind_expiring_vouchers(p_user uuid)
returns void language sql security definer set search_path = public as $$
  insert into public.notifications (user_id, kind, title, body, link, ref_id, event_key)
  select v.user_id, 'voucher', 'Voucher kamu segera berakhir',
         'Kode ' || v.code || ' (' || case when v.discount_type = 'percent' then 'diskon ' || v.value || '%' else 'potongan ' || public.rp_text(v.value) end
           || ') berlaku sampai ' || to_char(v.expires_at at time zone 'Asia/Jakarta', 'DD/MM HH24:MI') || '. Pakai sebelum hangus ya.',
         case when v.source = 'loyalty' then '#loyalty' else '#voucher' end, v.code, 'voucher:' || v.id || ':expiring'
    from public.vouchers v
   where v.user_id = p_user and v.status = 'available' and v.expires_at > now() and v.expires_at <= now() + interval '3 days'
  on conflict (user_id, event_key) do nothing;
$$;

create or replace function public.my_notifications(p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'NOT_LOGGED_IN'; end if;
  perform public.announce_due();
  perform public.remind_expiring_vouchers(v_uid);
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
           when 'voucher' then n.ref_id is null or exists (select 1 from public.vouchers v where v.code = n.ref_id and v.user_id = v_uid)
           else true end)
        order by n.created_at desc, n.id desc)
      from (select * from public.notifications where user_id = v_uid
             order by created_at desc, id desc limit greatest(1, least(p_limit, 200))) n), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- admin
create or replace function public.admin_loyalty_customers(p_search text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s text := trim(coalesce(p_search, ''));
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'spend')::int desc) from (
    select jsonb_build_object('id', p.id, 'name', p.full_name, 'phone', p.phone,
      'spend', public.loyalty_spend(p.id),
      'paid_orders', (select count(*) from public.loyalty_ledger l where l.user_id = p.id and l.kind = 'earn')
                   - (select count(*) from public.loyalty_ledger l where l.user_id = p.id and l.kind = 'reverse'),
      'rewards', (select count(*) from public.loyalty_rewards r where r.user_id = p.id),
      'used', (select count(*) from public.loyalty_rewards r join public.vouchers v on v.id = r.voucher_id where r.user_id = p.id and v.status = 'used'),
      'available', (select count(*) from public.loyalty_rewards r join public.vouchers v on v.id = r.voucher_id where r.user_id = p.id and public.voucher_state(v) = 'available'),
      'highest', (select x.name from public.loyalty_rewards r join public.loyalty_tiers x on x.id = r.tier_id where r.user_id = p.id order by x.threshold desc limit 1),
      'next', (select jsonb_build_object('threshold', n.threshold, 'name', t.name) from public.loyalty_next(p.id, public.loyalty_spend(p.id)) n join public.loyalty_tiers t on t.id = n.tier_id)) x
    from public.profiles p
   where (s = '' or p.full_name ilike '%' || s || '%' or p.phone ilike '%' || s || '%' or p.id::text = s)
     and (s <> '' or exists (select 1 from public.loyalty_ledger l where l.user_id = p.id))
   limit 300) q), '[]');
end $$;

create or replace function public.admin_loyalty_history(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  return jsonb_build_object(
    'spend', public.loyalty_spend(p_user),
    'ledger', coalesce((select jsonb_agg(jsonb_build_object('kind', l.kind, 'amount', l.amount, 'at', l.created_at, 'order', o.order_number, 'status', o.status) order by l.created_at desc, l.id desc)
                from public.loyalty_ledger l left join public.orders o on o.id = l.order_id where l.user_id = p_user), '[]'),
    'rewards', coalesce((select jsonb_agg(jsonb_build_object('tier', t.name, 'threshold', t.threshold, 'cycle', r.cycle, 'at', r.created_at,
                'spend_at', r.spend_at, 'voucher', v.code, 'voucher_status', public.voucher_state(v), 'used_order', uo.order_number,
                'manual', r.granted_by is not null) order by r.created_at desc)
                from public.loyalty_rewards r join public.loyalty_tiers t on t.id = r.tier_id
                left join public.vouchers v on v.id = r.voucher_id left join public.orders uo on uo.id = v.used_order_id
               where r.user_id = p_user), '[]'));
end $$;

create or replace function public.admin_loyalty_tier_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  return coalesce((select jsonb_object_agg(t.id, jsonb_build_object(
      'issued', (select count(*) from public.loyalty_rewards r where r.tier_id = t.id),
      'used', (select count(*) from public.loyalty_rewards r join public.vouchers v on v.id = r.voucher_id where r.tier_id = t.id and v.status = 'used'),
      'qualify_missing', (select count(*) from public.profiles p
                           where public.loyalty_spend(p.id) >= t.threshold
                             and not exists (select 1 from public.loyalty_rewards r where r.tier_id = t.id and r.user_id = p.id))))
    from public.loyalty_tiers t), '{}');
end $$;

-- on purpose: reward customers who already passed this tier's threshold but never got it
create or replace function public.admin_loyalty_grant_existing(p_tier_id bigint)
returns integer language plpgsql security definer set search_path = public as $$
declare t public.loyalty_tiers; r record; c integer; n integer := 0; v_spend integer;
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  select * into t from public.loyalty_tiers where id = p_tier_id;
  if not found then raise exception 'TIER_NOT_FOUND'; end if;
  if not t.is_active then raise exception 'TIER_INACTIVE'; end if;
  for r in select p.id from public.profiles p where public.loyalty_spend(p.id) >= t.threshold loop
    perform pg_advisory_xact_lock(hashtext('loyalty:' || r.id::text));
    v_spend := public.loyalty_spend(r.id);
    for c in 1 .. case when t.recurring then floor(v_spend::numeric / t.threshold)::int else 1 end loop
      if public.loyalty_issue(r.id, t, c, v_spend, null, auth.uid()) is not null then n := n + 1; end if;
    end loop;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- grants
revoke execute on function public.loyalty_issue(uuid, public.loyalty_tiers, integer, integer, uuid, uuid) from public, anon, authenticated;
revoke execute on function public.loyalty_check(uuid, integer, integer, uuid) from public, anon, authenticated;
revoke execute on function public.loyalty_spend(uuid) from public, anon, authenticated;
revoke execute on function public.loyalty_amount(public.orders) from public, anon, authenticated;
revoke execute on function public.loyalty_next(uuid, integer) from public, anon, authenticated;
revoke execute on function public.remind_expiring_vouchers(uuid) from public, anon, authenticated;
revoke execute on function public.my_loyalty() from public, anon;
grant execute on function public.my_loyalty() to authenticated;
revoke execute on function public.admin_loyalty_customers(text) from public, anon;
revoke execute on function public.admin_loyalty_history(uuid) from public, anon;
revoke execute on function public.admin_loyalty_tier_stats() from public, anon;
revoke execute on function public.admin_loyalty_grant_existing(bigint) from public, anon;
grant execute on function public.admin_loyalty_customers(text) to authenticated;
grant execute on function public.admin_loyalty_history(uuid) to authenticated;
grant execute on function public.admin_loyalty_tier_stats() to authenticated;
grant execute on function public.admin_loyalty_grant_existing(bigint) to authenticated;

commit;
