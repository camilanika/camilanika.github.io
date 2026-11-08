-- =====================================================================
-- Migration 019: customers can't read admin-only order fields (OBS-12, part 2 of 2)
-- Run AFTER migration 018 and after the website from the same pull request is live: the old admin.html
-- reads orders with select("*"), which stops working once this runs. Safe to run twice.
--
-- Customers (and guests) keep read access to the order fields the shop shows them. Internal fields
-- (classification note/review/source, payment_env, payment_issue, payment_ref/provider, snap_token,
-- access_token, promotion_id, voucher_id, completed_at_estimated) are only readable through
-- admin_list_orders() (migration 018) and the other admin functions.
--
-- Note for later migrations: orders no longer has a table-wide SELECT for anon/authenticated.
-- A new column is hidden from customers until it is added to the GRANT below, which is the safe default.
-- =====================================================================
do $$ begin
  if to_regprocedure('public.admin_list_orders(text[], text, uuid, integer)') is null then
    raise exception 'Run migration 018 first (and merge the website that uses admin_list_orders).';
  end if;
end $$;

-- Row access is unchanged (policy orders_select: own orders, or admin; guests get no rows). This limits the columns.
revoke select on public.orders from anon, authenticated;
grant select (id, order_number, user_id, status, subtotal, discount, shipping_discount, total,
              promo_code, gifts, customer_name, phone, email, address, notes, payment_method,
              paid_at, expires_at, created_at, updated_at, completed_at,
              delivery_lat, delivery_lng, delivery_km, delivery_fee, snap_redirect_url)
  on public.orders to anon, authenticated;   -- anon still gets no rows (policy), just no error

