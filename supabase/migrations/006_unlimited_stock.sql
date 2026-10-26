-- =====================================================================
-- Migration 006: unlimited stock + simpler stock editing
-- Safe to run on the live database (and safe to run twice).
--
-- inventory.unlimited = true  -> always available, no counting
-- admin_set_stock(variant, n) -> n = exact number available now; null = unlimited
-- Existing variants keep their numbers; NEW variants start as unlimited.
-- =====================================================================
begin;

alter table public.inventory add column if not exists unlimited boolean not null default false;
alter table public.inventory alter column unlimited set default true;

-- 1. Admin: set what is available (null = unlimited, 0 = sold out, n = exactly n left)
create or replace function public.admin_set_stock(p_variant_id bigint, p_available integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_inv public.inventory; v_new integer;
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  if p_available is not null and p_available < 0 then raise exception 'INVALID_AMOUNT'; end if;
  select * into v_inv from public.inventory where variant_id = p_variant_id for update;
  if not found then raise exception 'VARIANT_NOT_FOUND'; end if;

  if p_available is null then
    update public.inventory set unlimited = true where variant_id = p_variant_id;
    insert into public.stock_movements (variant_id, change, reason, note, created_by)
    values (p_variant_id, 0, 'adjustment', 'Set tak terbatas', auth.uid());
  else
    v_new := v_inv.reserved + p_available;   -- unpaid orders keep their reservation
    update public.inventory set unlimited = false, stock = v_new where variant_id = p_variant_id;
    insert into public.stock_movements (variant_id, change, reason, note, created_by)
    values (p_variant_id, v_new - v_inv.stock, 'adjustment',
            case when p_available = 0 then 'Dikosongkan' else 'Stok diatur ke ' || p_available end, auth.uid());
  end if;
  return jsonb_build_object('variant_id', p_variant_id, 'unlimited', p_available is null, 'available', p_available);
end $$;
revoke execute on function public.admin_set_stock(bigint, integer) from public, anon;
grant execute on function public.admin_set_stock(bigint, integer) to authenticated;

-- 2. Checkout: unlimited variants skip the stock check and are not reserved
do $$
declare v_src text;
begin
  v_src := pg_get_functiondef('public.quote_cart(jsonb, text)'::regprocedure);
  if position('unl' in v_src) = 0 then
    v_src := replace(v_src,
      'max(greatest(coalesce(i.stock,0) - coalesce(i.reserved,0), 0)) as available',
      'max(greatest(coalesce(i.stock,0) - coalesce(i.reserved,0), 0)) as available, bool_or(coalesce(i.unlimited, false)) as unl');
    v_src := replace(v_src,
      'if v_short.qty > v_short.available then',
      'if not v_short.unl and v_short.qty > v_short.available then');
    if position('v_short.unl' in v_src) = 0 or position('as unl' in v_src) = 0 then raise exception 'quote_cart patch failed'; end if;
    execute v_src;
  end if;

  v_src := pg_get_functiondef('public.create_order(uuid, jsonb, text, text, text, text, text, text, integer)'::regprocedure);
  if position('not unlimited' in v_src) = 0 then
    v_src := replace(v_src,
      'where variant_id = (v_line->>''variant_id'')::bigint;',
      'where variant_id = (v_line->>''variant_id'')::bigint and not unlimited;');
    if position('not unlimited' in v_src) = 0 then raise exception 'create_order patch failed'; end if;
    execute v_src;
  end if;
end $$;

-- 3. Payment confirmed: count down finite stock only; never break stock >= reserved
create or replace function public.mark_order_paid(
  p_order_number text, p_payment_ref text default null, p_payment_method text default null)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_order public.orders;
  v_was_pending boolean;
begin
  select * into v_order from public.orders where order_number = p_order_number for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  if not (v_order.status = 'pending' or (v_order.status in ('expired','failed','cancelled') and v_order.paid_at is null)) then
    return v_order.status;  -- already paid / processing / completed
  end if;
  v_was_pending := v_order.status = 'pending';

  update public.inventory i
     set reserved = case when v_was_pending then greatest(i.reserved - x.qty, 0) else i.reserved end,
         stock = case when i.unlimited then i.stock
                      else greatest(i.stock - x.qty, case when v_was_pending then greatest(i.reserved - x.qty, 0) else i.reserved end) end
    from (select variant_id, sum(quantity) qty from public.order_items
           where order_id = v_order.id and variant_id is not null group by 1) x
   where i.variant_id = x.variant_id;

  insert into public.stock_movements (variant_id, change, reason, order_id)
  select oi.variant_id, -sum(oi.quantity), 'sale', v_order.id
    from public.order_items oi join public.inventory i on i.variant_id = oi.variant_id
   where oi.order_id = v_order.id and not i.unlimited
   group by oi.variant_id;

  update public.promotions set used_count = used_count + 1
   where id in (select v_order.promotion_id
                union select (g->>'promotion_id')::bigint from jsonb_array_elements(v_order.gifts) g);

  update public.orders
     set status = 'paid', paid_at = now(), payment_ref = p_payment_ref, payment_method = p_payment_method
   where id = v_order.id;
  return 'paid';
end $$;

-- 4. Shop menu: available = null means unlimited
do $$
declare v_src text;
begin
  v_src := pg_get_functiondef('public.get_menu()'::regprocedure);
  if position('i.unlimited' in v_src) = 0 then
    v_src := replace(v_src,
      '''available'', greatest(coalesce(i.stock,0) - coalesce(i.reserved,0), 0))',
      '''available'', case when i.unlimited then null else greatest(coalesce(i.stock,0) - coalesce(i.reserved,0), 0) end)');
    if position('i.unlimited' in v_src) = 0 then raise exception 'get_menu patch failed'; end if;
    execute v_src;
  end if;
end $$;

commit;
