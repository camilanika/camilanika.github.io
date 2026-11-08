-- =====================================================================
-- Migration 017: fixes from the QA inspection of 8 Nov 2026
-- (docs/test-cases-and-automation.docx, §4). Run after 016. Safe to run twice.
--
-- Stock and payment
--   DEF-002  one order can't hold more than 100 of the same item by splitting it over lines
--            (part of DEF-002: the server-side switch for online payment and rate limiting need
--            a decision from the shop owner and are not in this migration)
--   OBS-4    an order paid after its stock was resold is flagged (orders.payment_issue) and the
--            stock ledger records the real change, not the full quantity
--   OBS-22   each order line remembers how much stock it really reserved (order_items.reserved_qty),
--            so releasing or paying an order only gives back what it held
-- Promos and vouchers
--   OBS-1    unpaid orders count towards a promo's usage limit (quote and order creation)
--   OBS-2    a voucher stays with its order for the same 15-minute grace as release_expired_orders,
--            and a late payment whose voucher was taken meanwhile is flagged
--   OBS-8    promo_details only shows a promo's code while the promo is live
--   OBS-15   promo codes are stored trimmed and upper-case again (blank = automatic promo)
--   OBS-16   deleting an account revokes its unused vouchers
-- Delivery and notifications
--   OBS-14   a delivery fee is never negative; order totals can't be negative
--   OBS-17   the "order created" notification gives the real payment deadline
-- Cashflow
--   OBS-6    the "belum dibayar" list shows every unpaid sale, like the banner that links to it
--   OBS-19   card ("Kartu") is accepted for offline sales and expenses, as the forms and docs offer it
--   OBS-20   bad dates, filters and page numbers get readable error codes, not database errors
--   OBS-21   a sale can't be paid before it was ordered (5 minutes slack instead of a whole day)
-- Hardening
--   API roles lose TRUNCATE, REFERENCES and TRIGGER on public tables (never used through the API)
-- =====================================================================

-- ---------------------------------------------------------------- helper: patch a function's source safely
-- Replaces one piece of a function's current source. Already patched = no-op; source changed by
-- someone else = the migration stops instead of guessing.
create or replace function pg_temp.qa_patch(p_fn text, p_old text, p_new text) returns void language plpgsql as $$
declare v text;
begin
  v := pg_get_functiondef(p_fn::regprocedure);
  if position(p_new in v) > 0 then return; end if;
  if position(p_old in v) = 0 then raise exception 'qa_patch: % does not contain the expected text: %', p_fn, left(p_old, 80); end if;
  execute replace(v, p_old, p_new);
end $$;

-- ---------------------------------------------------------------- new columns
alter table public.orders add column if not exists payment_issue text;
comment on column public.orders.payment_issue is
  'Set when a payment needs an admin to look: OVERSOLD:<variant>:<units> (paid after the stock was sold to others), VOUCHER_CONFLICT (the voucher went to another order meanwhile).';
alter table public.order_items add column if not exists reserved_qty integer;
comment on column public.order_items.reserved_qty is
  'Units this line reserved when the order was created (0 for unlimited stock). NULL on lines made before migration 017 = quantity.';

-- ---------------------------------------------------------------- DEF-002 + OBS-22: order lines
create or replace function public.trg_order_item_limits()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.variant_id is not null then
    if new.quantity + coalesce((select sum(quantity) from public.order_items
                                 where order_id = new.order_id and variant_id = new.variant_id), 0) > 100 then
      raise exception 'INVALID_QUANTITY';
    end if;
    new.reserved_qty := case when coalesce((select unlimited from public.inventory where variant_id = new.variant_id), true)
                             then 0 else new.quantity end;
  end if;
  return new;
end $$;
revoke execute on function public.trg_order_item_limits() from public, anon, authenticated;
drop trigger if exists trg_order_item_limits on public.order_items;
create trigger trg_order_item_limits before insert on public.order_items
  for each row execute function public.trg_order_item_limits();

-- the quote refuses the same carts, so the shop shows the error before checkout
create or replace function public.quote_cart(p_items jsonb, p_promo_code text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if jsonb_typeof(p_items) = 'array' and exists (
       select 1 from jsonb_array_elements(p_items) e
        where jsonb_typeof(e->'quantity') = 'number' and e ? 'variant_id'
        group by e->>'variant_id' having sum((e->>'quantity')::numeric) > 100) then
    raise exception 'INVALID_QUANTITY';
  end if;
  return public.quote_cart_v(p_items, p_promo_code, auth.uid());
end $$;

-- ---------------------------------------------------------------- OBS-1: new orders (promo limit under concurrency)
create or replace function public.trg_order_limits()
returns trigger language plpgsql security definer set search_path = public as $$
declare p public.promotions; v_pending int;
begin
  -- a promo's usage limit also counts orders that are not paid yet (two checkouts at once)
  if new.promotion_id is not null then
    select * into p from public.promotions where id = new.promotion_id for update;
    if found and p.usage_limit is not null then
      v_pending := (select count(*) from public.orders
                     where promotion_id = p.id and status = 'pending' and expires_at > now() - interval '15 minutes');
      if p.used_count + v_pending >= p.usage_limit then raise exception 'PROMO_LIMIT_REACHED'; end if;
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.trg_order_limits() from public, anon, authenticated;
drop trigger if exists trg_order_limits on public.orders;
create trigger trg_order_limits before insert on public.orders
  for each row execute function public.trg_order_limits();

select pg_temp.qa_patch('public.quote_cart_v(jsonb, text, uuid)',
  'and (pr.usage_limit is null or pr.used_count < pr.usage_limit)',
  'and (pr.usage_limit is null or pr.used_count + (select count(*) from public.orders po where po.promotion_id = pr.id and po.status = ''pending'' and po.expires_at > now() - interval ''15 minutes'') < pr.usage_limit)');

-- ---------------------------------------------------------------- OBS-2: voucher grace period
select pg_temp.qa_patch('public.release_stale_voucher(bigint)',
  'and o.expires_at < now();',
  'and o.expires_at < now() - interval ''15 minutes'';');

-- ---------------------------------------------------------------- OBS-22: release what the order held
select pg_temp.qa_patch('public.release_order(text, text)',
  'select variant_id, sum(quantity) qty from public.order_items',
  'select variant_id, sum(coalesce(reserved_qty, quantity)) qty from public.order_items');

-- ---------------------------------------------------------------- OBS-2, OBS-4, OBS-22: payment
create or replace function public.mark_order_paid(
  p_order_number text, p_payment_ref text default null, p_payment_method text default null)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_order public.orders;
  v_was_pending boolean;
  r record;
  v_inv public.inventory;
  v_stock integer;
  v_issue text[] := '{}';
  v_n integer;
begin
  select * into v_order from public.orders where order_number = p_order_number for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  if not (v_order.status = 'pending' or (v_order.status in ('expired','failed','cancelled') and v_order.paid_at is null)) then
    return v_order.status;  -- already paid / processing / completed
  end if;
  v_was_pending := v_order.status = 'pending';

  for r in select variant_id, sum(quantity)::int qty, sum(coalesce(reserved_qty, quantity))::int held
             from public.order_items where order_id = v_order.id and variant_id is not null
            group by variant_id order by variant_id loop
    select * into v_inv from public.inventory where variant_id = r.variant_id for update;
    continue when not found;
    if v_was_pending then v_inv.reserved := greatest(v_inv.reserved - r.held, 0); end if;  -- this order's hold ends
    if not v_inv.unlimited then
      v_stock := greatest(v_inv.stock - r.qty, v_inv.reserved);   -- never sell stock other orders hold
      if v_stock > v_inv.stock - r.qty then
        v_issue := v_issue || format('OVERSOLD:%s:%s', r.variant_id, v_stock - (v_inv.stock - r.qty));
      end if;
      if v_stock <> v_inv.stock then
        insert into public.stock_movements (variant_id, change, reason, order_id)
        values (r.variant_id, v_stock - v_inv.stock, 'sale', v_order.id);
      end if;
      v_inv.stock := v_stock;
    end if;
    update public.inventory set reserved = v_inv.reserved, stock = v_inv.stock where variant_id = r.variant_id;
  end loop;

  update public.promotions set used_count = used_count + 1
   where id in (select v_order.promotion_id
                union select (g->>'promotion_id')::bigint from jsonb_array_elements(v_order.gifts) g);

  if v_order.voucher_id is not null then
    update public.vouchers
       set status = 'used', used_order_id = v_order.id, used_at = now(), reserved_order_id = null,
           user_id = coalesce(user_id, v_order.user_id)
     where id = v_order.voucher_id
       and (status = 'reserved' and reserved_order_id = v_order.id
            or status = 'available');         -- paid late, after the hold was released
    get diagnostics v_n = row_count;
    if v_n > 0 then
      insert into public.voucher_events (voucher_id, event, order_id) values (v_order.voucher_id, 'used', v_order.id);
    else
      v_issue := v_issue || 'VOUCHER_CONFLICT'::text;  -- the voucher went to another order meanwhile
    end if;
  end if;

  update public.orders
     set status = 'paid', paid_at = now(), payment_ref = p_payment_ref, payment_method = p_payment_method,
         payment_issue = nullif(array_to_string(v_issue, '; '), '')
   where id = v_order.id;
  return 'paid';
end $$;
revoke execute on function public.mark_order_paid(text, text, text) from public, anon, authenticated;
grant execute on function public.mark_order_paid(text, text, text) to service_role;

-- ---------------------------------------------------------------- OBS-8: promo codes stay secret until live
select pg_temp.qa_patch('public.promo_details(bigint)',
  '''code'', pr.code,',
  '''code'', case when public.promo_is_live(pr) then pr.code end,');

-- ---------------------------------------------------------------- OBS-15: promo codes trimmed and upper-case
select pg_temp.qa_patch('public.trg_code_unique()',
  'if tg_table_name <> ''promotions'' then new.code := upper(trim(new.code)); end if;',
  'if tg_table_name = ''promotions'' then new.code := nullif(upper(trim(new.code)), ''''); else new.code := upper(trim(new.code)); end if;');
update public.promotions set code = nullif(upper(trim(code)), '')
 where code is distinct from nullif(upper(trim(code)), '');

-- ---------------------------------------------------------------- OBS-16: deleted accounts lose their vouchers
create or replace function public.trg_revoke_vouchers_of_deleted_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  with r as (
    update public.vouchers set status = 'revoked', reserved_order_id = null
     where user_id = old.id and status in ('pending', 'available', 'reserved')
    returning id)
  insert into public.voucher_events (voucher_id, event, note) select id, 'revoked', 'account deleted' from r;
  return old;
end $$;
revoke execute on function public.trg_revoke_vouchers_of_deleted_user() from public, anon, authenticated;
drop trigger if exists trg_revoke_vouchers_of_deleted_user on auth.users;
create trigger trg_revoke_vouchers_of_deleted_user before delete on auth.users
  for each row execute function public.trg_revoke_vouchers_of_deleted_user();

-- ---------------------------------------------------------------- OBS-14: no negative fees or totals
select pg_temp.qa_patch('public.delivery_quote(double precision, double precision)',
  '  if v_fee is null then',
  '  if v_fee < 0 then v_fee := 0; end if;  -- a mistyped tier never pays the customer
  if v_fee is null then');
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'orders_amounts_not_negative') then
    alter table public.orders add constraint orders_amounts_not_negative
      check (total >= 0 and coalesce(delivery_fee, 0) >= 0) not valid;   -- new orders only
  end if;
end $$;

-- ---------------------------------------------------------------- OBS-17: real payment deadline in notifications
select pg_temp.qa_patch('public.trg_notify_order()',
  '''Pesanan '' || n || '' menunggu pembayaran. Selesaikan dalam 30 menit.''',
  '''Pesanan '' || n || '' menunggu pembayaran. Bayar sebelum '' || to_char(new.expires_at at time zone ''Asia/Jakarta'', ''HH24.MI'') || '' WIB.''');
select pg_temp.qa_patch('public.trg_notify_order()',
  ''' batal karena belum dibayar dalam 30 menit.''',
  ''' batal karena belum dibayar sampai batas waktu.''');

-- ---------------------------------------------------------------- OBS-19: card payments
alter table public.offline_orders drop constraint if exists offline_orders_payment_method_check;
alter table public.offline_orders add constraint offline_orders_payment_method_check
  check (payment_method in ('cash','bank_transfer','qris','card','other'));
alter table public.expenses drop constraint if exists expenses_payment_method_check;
alter table public.expenses add constraint expenses_payment_method_check
  check (payment_method in ('cash','bank_transfer','qris','card','other'));
select pg_temp.qa_patch('public.cashflow_save_offline_order(jsonb)', '(''cash'',''bank_transfer'',''qris'',''other'')', '(''cash'',''bank_transfer'',''qris'',''card'',''other'')');
select pg_temp.qa_patch('public.cashflow_mark_offline_paid(bigint, integer, timestamp with time zone, text)', '(''cash'',''bank_transfer'',''qris'',''other'')', '(''cash'',''bank_transfer'',''qris'',''card'',''other'')');
select pg_temp.qa_patch('public.cashflow_save_expense(jsonb)', '(''cash'',''bank_transfer'',''qris'',''other'')', '(''cash'',''bank_transfer'',''qris'',''card'',''other'')');

-- ---------------------------------------------------------------- OBS-21: paid before ordered
select pg_temp.qa_patch('public.cashflow_save_offline_order(jsonb)',
  '- interval ''1 day'' then raise exception ''PAID_BEFORE', '- interval ''5 minutes'' then raise exception ''PAID_BEFORE');
select pg_temp.qa_patch('public.cashflow_mark_offline_paid(bigint, integer, timestamp with time zone, text)',
  '- interval ''1 day'' then raise exception ''PAID_BEFORE', '- interval ''5 minutes'' then raise exception ''PAID_BEFORE');

-- ---------------------------------------------------------------- OBS-6 + OBS-20: transaction list
create or replace function public.cf_date(p jsonb, k text) returns date language plpgsql immutable as $$
begin
  return (p->>k)::date;
exception when others then raise exception 'INVALID_DATE';
end $$;
create or replace function public.cf_bool(p jsonb, k text) returns boolean language plpgsql immutable as $$
begin
  return (p->>k)::boolean;
exception when others then raise exception 'INVALID_FILTER:%', k;
end $$;
revoke execute on function public.cf_date(jsonb, text), public.cf_bool(jsonb, text) from public, anon, authenticated;
select pg_temp.qa_patch('public.cashflow_transactions(jsonb)',
  'coalesce((p->>''review'')::boolean, false)', 'coalesce(public.cf_bool(p, ''review''), false)');
select pg_temp.qa_patch('public.cashflow_transactions(jsonb)',
  'v_page integer := greatest(coalesce(public.cf_int(p, ''page''), 1), 1);',
  'v_page integer := least(greatest(coalesce(public.cf_int(p, ''page''), 1), 1), 100000);');
select pg_temp.qa_patch('public.cashflow_transactions(jsonb)',
  'public.cf_range((p->>''from'')::date, (p->>''to'')::date)', 'public.cf_range(public.cf_date(p, ''from''), public.cf_date(p, ''to''))');
select pg_temp.qa_patch('public.cashflow_transactions(jsonb)',
  'where f.deleted_at is null and coalesce(f.paid_at, f.order_date) >= r.r_from and coalesce(f.paid_at, f.order_date) < r.r_to',
  'where f.deleted_at is null and (v_pstat = ''unpaid'' and f.payment_status = ''unpaid''   -- money still owed, from any date (OBS-6)
            or coalesce(f.paid_at, f.order_date) >= r.r_from and coalesce(f.paid_at, f.order_date) < r.r_to)');

-- ---------------------------------------------------------------- hardening
revoke truncate, references, trigger on all tables in schema public from anon, authenticated;
