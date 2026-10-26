-- =====================================================================
-- Migration 009: order history page + continue paying a pending order
-- Safe to run on the live database (and safe to run twice).
--
-- orders.snap_token / snap_redirect_url: the Midtrans payment link, saved by the
-- create-payment function, so a customer can reopen it from "Pesanan saya"
-- (on any device when logged in). Only returned while the order is still pending.
-- get_order_status (guest orders) now returns the full details for the order page.
-- =====================================================================
begin;

alter table public.orders
  add column if not exists snap_token text,
  add column if not exists snap_redirect_url text;

create or replace function public.get_order_status(p_order_number text, p_access_token uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'order_number', o.order_number, 'status', o.status, 'total', o.total,
    'subtotal', o.subtotal, 'discount', o.discount, 'promo_code', o.promo_code, 'gifts', o.gifts,
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
