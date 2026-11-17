-- =====================================================================
-- Migration 023: test (mock) payments through iPaymu Sandbox while the shop takes real payments
-- Safe to run on the live database (and safe to run twice).
--
-- Anyone who opens the shop with ?test=1 pays through iPaymu Sandbox (no real money), so iPaymu can test
-- the checkout without an admin account. Those orders are tagged payment_env = 'sandbox', which makes them
-- Mock orders (never counted in Cashflow or Best Seller) and marked "Sandbox" in Admin → Pesanan.
--   * shop_settings.sandbox_tests: the switch (Admin → Toko). On by default.
--   * A Sandbox payment never earns loyalty spending or rewards, and never activates a referral voucher
--     that waits for the first payment, so fake payments can't be turned into real discounts.
-- create-payment and ipaymu-webhook (Edge Functions) choose the iPaymu account per order; see their comments.
-- =====================================================================
begin;

alter table public.shop_settings add column if not exists sandbox_tests boolean not null default true;

-- loyalty: what the customer paid for items (the ongkir they actually paid is left out); Sandbox orders count 0
create or replace function public.loyalty_amount(o public.orders)
returns integer language sql stable security definer set search_path = public as $$
  select case when o.payment_env = 'sandbox' then 0 else
         greatest(o.total - case when (select loyalty_include_shipping from public.shop_settings where id = 1) then 0
                                 else greatest(coalesce(o.delivery_fee, 0) - coalesce(o.shipping_discount, 0), 0) end, 0) end;
$$;
revoke execute on function public.loyalty_amount(public.orders) from public, anon, authenticated;

-- referral rewards that wait for the first payment become usable then (a Sandbox payment doesn't count)
create or replace function public.trg_activate_referral_voucher()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if new.user_id is null or new.status <> 'paid' or old.status = 'paid' then return null; end if;
  if new.payment_env = 'sandbox' then return null; end if;
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
revoke execute on function public.trg_activate_referral_voucher() from public, anon, authenticated;

commit;
