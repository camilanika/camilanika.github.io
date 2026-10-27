-- =====================================================================
-- Migration 013: vouchers that only take money off the delivery fee (ongkir)
-- Safe to run on the live database (and safe to run twice).
--
-- discount_type 'shipping' (vouchers, referral campaign rewards, loyalty milestones):
--   value = the most it takes off the ongkir (e.g. Rp10.000; a big number = free delivery).
--   Item prices are not touched, so automatic item promos still apply alongside it.
--   Minimum purchase and eligible products are checked on the items as usual.
--   If the order has no ongkir (free radius / fees off), the voucher can't be used (it would be wasted).
-- orders.shipping_discount = what the voucher took off the ongkir. It is also included in
-- orders.discount, so the Midtrans bill (items − discount + ongkir) still adds up to the total.
-- =====================================================================
begin;

alter table public.vouchers drop constraint if exists vouchers_discount_type_check;
alter table public.vouchers add constraint vouchers_discount_type_check check (discount_type in ('percent','fixed','shipping'));
alter table public.referral_campaigns drop constraint if exists referral_campaigns_discount_type_check;
alter table public.referral_campaigns add constraint referral_campaigns_discount_type_check check (discount_type in ('percent','fixed','shipping'));
alter table public.loyalty_tiers drop constraint if exists loyalty_tiers_discount_type_check;
alter table public.loyalty_tiers add constraint loyalty_tiers_discount_type_check check (discount_type in ('percent','fixed','shipping'));

alter table public.orders add column if not exists shipping_discount integer not null default 0 check (shipping_discount >= 0);

-- wording used in notifications
create or replace function public.offer_text(p_type text, p_value integer, p_min integer, p_max integer)
returns text language sql immutable as $$
  select case p_type when 'percent' then 'Diskon ' || p_value || '%'
                     when 'shipping' then 'Gratis ongkir s/d ' || public.rp_text(p_value)
                     else 'Potongan ' || public.rp_text(p_value) end
      || case when p_type = 'percent' and p_max is not null then ' (maks. ' || public.rp_text(p_max) || ')' else '' end
      || case when coalesce(p_min, 0) > 0 then ', min. belanja ' || public.rp_text(p_min) else '' end;
$$;
create or replace function public.tier_reward_text(t public.loyalty_tiers)
returns text language sql immutable as $$
  select 'voucher ' || case when t.discount_type = 'percent' then t.value || '%'
                            when t.discount_type = 'shipping' then 'gratis ongkir s/d ' || public.rp_text(t.value)
                            else public.rp_text(t.value) end;
$$;
create or replace function public.remind_expiring_vouchers(p_user uuid)
returns void language sql security definer set search_path = public as $$
  insert into public.notifications (user_id, kind, title, body, link, ref_id, event_key)
  select v.user_id, 'voucher', 'Voucher kamu segera berakhir',
         'Kode ' || v.code || ' (' || lower(public.offer_text(v.discount_type, v.value, null, null))
           || ') berlaku sampai ' || to_char(v.expires_at at time zone 'Asia/Jakarta', 'DD/MM HH24:MI') || '. Pakai sebelum hangus ya.',
         case when v.source = 'loyalty' then '#loyalty' else '#voucher' end, v.code, 'voucher:' || v.id || ':expiring'
    from public.vouchers v
   where v.user_id = p_user and v.status = 'available' and v.expires_at > now() and v.expires_at <= now() + interval '3 days'
  on conflict (user_id, event_key) do nothing;
$$;
revoke execute on function public.remind_expiring_vouchers(uuid) from public, anon, authenticated;

-- loyalty: what the customer paid for items (the ongkir they actually paid is left out)
create or replace function public.loyalty_amount(o public.orders)
returns integer language sql stable security definer set search_path = public as $$
  select greatest(o.total - case when (select loyalty_include_shipping from public.shop_settings where id = 1) then 0
                                 else greatest(coalesce(o.delivery_fee, 0) - coalesce(o.shipping_discount, 0), 0) end, 0);
$$;
revoke execute on function public.loyalty_amount(public.orders) from public, anon, authenticated;

-- price calculator: a shipping voucher leaves item discounts alone and reports its cap
do $$
declare v_src text;
begin
  v_src := pg_get_functiondef('public.quote_cart_v(jsonb, text, uuid)'::regprocedure);
  if position('shipping_cap' in v_src) = 0 then
    v_src := replace(v_src, '      v_best_disc := case when v_vch.discount_type = ''percent''',
                            '      if v_vch.discount_type <> ''shipping'' then
      v_best_disc := case when v_vch.discount_type = ''percent''');
    v_src := replace(v_src, '      v_best := null;                   -- the voucher replaces automatic discounts (gifts still apply)',
                            '      v_best := null;                   -- the voucher replaces automatic discounts (gifts still apply)
      end if;                           -- a shipping voucher keeps automatic item discounts');
    v_src := replace(v_src, '''voucher_id'', v_vch.id,',
                            '''voucher_id'', v_vch.id, ''voucher_code'', v_vch.code,
    ''shipping_cap'', case when v_vch.discount_type = ''shipping'' then v_vch.value end,');
    v_src := replace(v_src, '''promo_name'', coalesce(v_best.name, case when v_vch.id is not null then',
                            '''promo_name'', coalesce(v_best.name, case when v_vch.id is not null and v_vch.discount_type <> ''shipping'' then');
    if position('shipping_cap' in v_src) = 0 or position('a shipping voucher keeps' in v_src) = 0 then
      raise exception 'quote_cart_v patch failed';
    end if;
    execute v_src;
  end if;
end $$;

-- create_order: take the voucher off the ongkir (never more than the ongkir)
do $$
declare v_src text;
begin
  v_src := pg_get_functiondef('public.create_order(uuid, jsonb, text, text, text, text, text, text, integer, double precision, double precision)'::regprocedure);
  if position('v_ship' in v_src) = 0 then
    v_src := replace(v_src, '  v_vid    bigint;', '  v_vid    bigint;
  v_ship   integer := 0;');
    v_src := replace(v_src, '  v_quote := public.quote_cart_v(p_items, p_promo_code, p_user_id);',
'  v_quote := public.quote_cart_v(p_items, p_promo_code, p_user_id);
  if v_quote->>''shipping_cap'' is not null then
    v_ship := least((v_quote->>''shipping_cap'')::int, v_fee);
    if v_ship <= 0 then raise exception ''VOUCHER_NO_SHIPPING''; end if;
  end if;');
    v_src := replace(v_src, '(v_quote->>''subtotal'')::int, (v_quote->>''discount'')::int, (v_quote->>''total'')::int + v_fee,',
                            '(v_quote->>''subtotal'')::int, (v_quote->>''discount'')::int + v_ship, (v_quote->>''total'')::int + v_fee - v_ship,');
    v_src := replace(v_src, '  returning * into v_order;',
'  returning * into v_order;
  if v_ship > 0 then update public.orders set shipping_discount = v_ship where id = v_order.id; end if;');
    v_src := replace(v_src, '''delivery_fee'', v_fee, ''delivery_km'', v_deliv->''km'', ''total'', v_order.total);',
                            '''delivery_fee'', v_fee, ''delivery_km'', v_deliv->''km'', ''total'', v_order.total,
    ''discount'', v_order.discount, ''shipping_discount'', v_ship);');
    if position('VOUCHER_NO_SHIPPING' in v_src) = 0 or position('+ v_fee - v_ship' in v_src) = 0 or position('''shipping_discount'', v_ship' in v_src) = 0 then
      raise exception 'create_order patch failed';
    end if;
    execute v_src;
  end if;
end $$;

-- guest order page shows the ongkir discount too
create or replace function public.get_order_status(p_order_number text, p_access_token uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'order_number', o.order_number, 'status', o.status, 'total', o.total,
    'subtotal', o.subtotal, 'discount', o.discount, 'shipping_discount', o.shipping_discount, 'promo_code', o.promo_code, 'gifts', o.gifts,
    'delivery_fee', o.delivery_fee, 'delivery_km', o.delivery_km,
    'delivery_lat', o.delivery_lat, 'delivery_lng', o.delivery_lng,
    'customer_name', o.customer_name, 'phone', o.phone, 'address', o.address, 'notes', o.notes,
    'payment_method', o.payment_method,
    'created_at', o.created_at, 'paid_at', o.paid_at, 'expires_at', o.expires_at,
    'snap_token', case when o.status = 'pending' and (o.expires_at is null or o.expires_at > now()) then o.snap_token end,
    'snap_redirect_url', case when o.status = 'pending' and (o.expires_at is null or o.expires_at > now()) then o.snap_redirect_url end,
    'items', (select jsonb_agg(jsonb_build_object('product_name', product_name, 'variant_name', variant_name,
                     'choices', choices, 'addon', addon, 'quantity', quantity, 'unit_price', unit_price,
                     'line_total', line_total) order by id)
                from public.order_items where order_id = o.id))
  from public.orders o
  where o.order_number = p_order_number and o.access_token = p_access_token;
$$;

commit;
