-- =====================================================================
-- Migration 008: delivery location on the map + delivery fee by distance
-- Safe to run on the live database (and safe to run twice).
--
-- shop_settings gets the shop's location (origin) and the fee table:
--   delivery_fee_enabled  off by default; until on, delivery is free and the map pin is optional
--   free_radius_km        free delivery up to this distance (e.g. Bukit Cimanggu City)
--   max_radius_km         farther than this = we don't deliver (customer is asked to chat)
--   fee_tiers             [{"up_to_km": 5, "fee": 10000}, ...]  (fill in from the Paxel app)
-- Distance = straight line from the shop pin to the customer's pin.
-- orders get delivery_lat / delivery_lng / delivery_km / delivery_fee; total includes the fee.
-- =====================================================================
begin;

alter table public.shop_settings
  add column if not exists origin_lat double precision not null default -6.5561334,
  add column if not exists origin_lng double precision not null default 106.7827129,
  add column if not exists origin_label text default 'Bukit Cimanggu City, Tanah Sareal, Bogor',
  add column if not exists delivery_fee_enabled boolean not null default false,
  add column if not exists free_radius_km numeric(6,2) not null default 2,
  add column if not exists max_radius_km numeric(6,2) not null default 25,
  add column if not exists fee_tiers jsonb not null default '[]';

alter table public.orders
  add column if not exists delivery_lat double precision,
  add column if not exists delivery_lng double precision,
  add column if not exists delivery_km numeric(7,2),
  add column if not exists delivery_fee integer not null default 0;

-- Fee for a customer location (anyone can ask; used by the cart preview and by create_order)
create or replace function public.delivery_quote(p_lat double precision, p_lng double precision)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  s public.shop_settings;
  v_km numeric;
  v_fee integer;
  t jsonb;
begin
  select * into s from public.shop_settings where id = 1;
  if p_lat is null or p_lng is null then
    return jsonb_build_object('ok', not s.delivery_fee_enabled, 'enabled', s.delivery_fee_enabled,
      'fee', 0, 'km', null, 'error', case when s.delivery_fee_enabled then 'LOCATION_REQUIRED' end);
  end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    return jsonb_build_object('ok', false, 'enabled', s.delivery_fee_enabled, 'fee', 0, 'km', null, 'error', 'LOCATION_INVALID');
  end if;
  -- haversine distance in km
  v_km := round((6371 * 2 * asin(sqrt(
            power(sin(radians(p_lat - s.origin_lat) / 2), 2) +
            cos(radians(s.origin_lat)) * cos(radians(p_lat)) * power(sin(radians(p_lng - s.origin_lng) / 2), 2))))::numeric, 2);
  if not s.delivery_fee_enabled then
    return jsonb_build_object('ok', true, 'enabled', false, 'fee', 0, 'km', v_km, 'free', true);
  end if;
  if v_km <= s.free_radius_km then
    return jsonb_build_object('ok', true, 'enabled', true, 'fee', 0, 'km', v_km, 'free', true);
  end if;
  if v_km > s.max_radius_km then
    return jsonb_build_object('ok', false, 'enabled', true, 'fee', null, 'km', v_km, 'error', 'OUT_OF_RANGE', 'max_km', s.max_radius_km);
  end if;
  select (x->>'fee')::int into v_fee
    from jsonb_array_elements(s.fee_tiers) x
   where (x->>'up_to_km')::numeric >= v_km
   order by (x->>'up_to_km')::numeric limit 1;
  if v_fee is null then
    return jsonb_build_object('ok', false, 'enabled', true, 'fee', null, 'km', v_km, 'error', 'OUT_OF_RANGE', 'max_km', s.max_radius_km);
  end if;
  return jsonb_build_object('ok', true, 'enabled', true, 'fee', v_fee, 'km', v_km, 'free', v_fee = 0);
end $$;
revoke execute on function public.delivery_quote(double precision, double precision) from public;
grant execute on function public.delivery_quote(double precision, double precision) to anon, authenticated, service_role;

-- Public delivery settings for the shop page (no admin-only data in here)
create or replace function public.delivery_settings()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('enabled', delivery_fee_enabled, 'origin_lat', origin_lat, 'origin_lng', origin_lng,
    'origin_label', origin_label, 'free_radius_km', free_radius_km, 'max_radius_km', max_radius_km, 'fee_tiers', fee_tiers)
  from public.shop_settings where id = 1;
$$;
revoke execute on function public.delivery_settings() from public;
grant execute on function public.delivery_settings() to anon, authenticated, service_role;

-- create_order: now also takes the customer's map pin and adds the delivery fee
drop function if exists public.create_order(uuid, jsonb, text, text, text, text, text, text, integer);
create or replace function public.create_order(
  p_user_id uuid, p_items jsonb, p_promo_code text,
  p_customer_name text, p_phone text, p_email text default null,
  p_address text default null, p_notes text default null,
  p_expires_minutes integer default 30,
  p_lat double precision default null, p_lng double precision default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_quote  jsonb;
  v_deliv  jsonb;
  v_fee    integer;
  v_order  public.orders;
  v_line   jsonb;
  v_number text;
begin
  if not public.is_shop_open() then raise exception 'SHOP_CLOSED'; end if;
  if coalesce(trim(p_customer_name), '') = '' then raise exception 'NAME_REQUIRED'; end if;
  if coalesce(trim(p_phone), '') = '' then raise exception 'PHONE_REQUIRED'; end if;

  v_deliv := public.delivery_quote(p_lat, p_lng);
  if not (v_deliv->>'ok')::boolean then raise exception '%', coalesce(v_deliv->>'error', 'DELIVERY_ERROR'); end if;
  v_fee := coalesce((v_deliv->>'fee')::int, 0);

  -- lock stock rows so two buyers can't take the last item at the same time
  perform 1 from public.inventory
   where variant_id in (select (x->>'variant_id')::bigint from jsonb_array_elements(p_items) x)
   order by variant_id for update;

  v_quote := public.quote_cart(p_items, p_promo_code);

  v_number := 'CN-' || to_char(now() at time zone 'Asia/Jakarta', 'YYMMDD') || '-'
              || upper(substr(md5(gen_random_uuid()::text), 1, 6));

  insert into public.orders (order_number, user_id, subtotal, discount, total, promotion_id, promo_code,
                             gifts, customer_name, phone, email, address, notes, expires_at,
                             delivery_lat, delivery_lng, delivery_km, delivery_fee)
  values (v_number, p_user_id,
          (v_quote->>'subtotal')::int, (v_quote->>'discount')::int, (v_quote->>'total')::int + v_fee,
          (v_quote->>'promotion_id')::bigint, v_quote->>'promo_code', v_quote->'gifts',
          trim(p_customer_name), trim(p_phone), nullif(trim(p_email), ''),
          p_address, p_notes, now() + make_interval(mins => p_expires_minutes),
          p_lat, p_lng, (v_deliv->>'km')::numeric, v_fee)
  returning * into v_order;

  for v_line in select * from jsonb_array_elements(v_quote->'items') loop
    insert into public.order_items (order_id, variant_id, product_id, product_name, variant_name,
                                    choices, addon, unit_price, quantity, line_total)
    values (v_order.id, (v_line->>'variant_id')::bigint, (v_line->>'product_id')::bigint,
            v_line->>'product_name', v_line->>'variant_name', v_line->'choices', v_line->>'addon',
            (v_line->>'unit_price')::int, (v_line->>'quantity')::int, (v_line->>'line_total')::int);
    update public.inventory set reserved = reserved + (v_line->>'quantity')::int
     where variant_id = (v_line->>'variant_id')::bigint and not unlimited;
  end loop;

  return v_quote || jsonb_build_object(
    'order_id', v_order.id, 'order_number', v_order.order_number,
    'access_token', v_order.access_token, 'expires_at', v_order.expires_at,
    'delivery_fee', v_fee, 'delivery_km', v_deliv->'km', 'total', v_order.total);
end $$;
revoke execute on function public.create_order(uuid, jsonb, text, text, text, text, text, text, integer, double precision, double precision) from public, anon, authenticated;
grant execute on function public.create_order(uuid, jsonb, text, text, text, text, text, text, integer, double precision, double precision) to service_role;

-- Guest order status now shows the delivery fee and pin too
create or replace function public.get_order_status(p_order_number text, p_access_token uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'order_number', o.order_number, 'status', o.status, 'total', o.total,
    'subtotal', o.subtotal, 'discount', o.discount, 'gifts', o.gifts,
    'delivery_fee', o.delivery_fee, 'delivery_km', o.delivery_km,
    'delivery_lat', o.delivery_lat, 'delivery_lng', o.delivery_lng, 'address', o.address,
    'created_at', o.created_at, 'paid_at', o.paid_at,
    'items', (select jsonb_agg(jsonb_build_object('product_name', product_name, 'variant_name', variant_name,
                     'choices', choices, 'addon', addon, 'quantity', quantity, 'line_total', line_total) order by id)
                from public.order_items where order_id = o.id))
  from public.orders o
  where o.order_number = p_order_number and o.access_token = p_access_token;
$$;

commit;
