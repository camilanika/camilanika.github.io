-- =====================================================================
-- Migration 015: Cashflow Summary leaves mock (test) orders out completely
-- Safe to run on the live database (and safe to run twice). Run after 014.
--
-- * cashflow_transactions never lists mock orders (online or offline).
-- * cashflow_summary no longer returns mock totals; "perlu ditinjau" and
--   "perkiraan tanggal selesai" only count Real orders.
-- * cashflow_menu_sales only reports Real sales.
-- Orders keep their Real/Mock label; it is changed from the Pesanan page
-- (cashflow_set_order_classification, unchanged).
-- =====================================================================
begin;

create or replace function public.cashflow_summary(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r record; v jsonb; v_exp bigint; v_exp_n integer;
begin
  perform public.cf_require_admin();
  select * into r from public.cf_range(p_from, p_to);

  select coalesce(sum(amount), 0), count(*) into v_exp, v_exp_n
    from public.expenses where deleted_at is null and expense_date >= r.r_from and expense_date < r.r_to;

  select jsonb_build_object(
      'from', p_from, 'to', p_to, 'timezone', 'Asia/Jakarta',
      'real_order_income',    coalesce(sum(total) filter (where kind = 'system'  and classification = 'real'), 0),
      'completed_real_orders', count(*)       filter (where kind = 'system'  and classification = 'real'),
      'offline_order_income', coalesce(sum(total) filter (where kind = 'offline' and classification = 'real'), 0),
      'offline_real_orders',   count(*)       filter (where kind = 'offline' and classification = 'real'),
      'total_income',         coalesce(sum(total) filter (where classification = 'real'), 0),
      'amount_only_orders',    count(*)       filter (where kind = 'offline' and classification = 'real' and entry_mode = 'amount'),
      'amount_only_value',    coalesce(sum(total) filter (where kind = 'offline' and classification = 'real' and entry_mode = 'amount'), 0))
    into v
    from public.cf_income(r.r_from, r.r_to);

  return v || jsonb_build_object(
    'total_expenses', v_exp,
    'expense_count', v_exp_n,
    'net_cashflow', (v->>'total_income')::bigint - v_exp,
    'total_items_sold', (select coalesce(sum(quantity), 0) from public.cf_menu_lines(r.r_from, r.r_to) where classification = 'real'),
    'orders_to_review', (select count(*) from public.orders o
                          where o.status = 'completed' and o.classification = 'real' and o.classification_review
                            and o.completed_at >= r.r_from and o.completed_at < r.r_to),
    'estimated_completion_dates', (select count(*) from public.orders o
                          where o.status = 'completed' and o.classification = 'real' and o.completed_at_estimated
                            and o.completed_at >= r.r_from and o.completed_at < r.r_to),
    'payments_mode', (select payments_mode from public.shop_settings where id = 1),
    'refunds_tracked', false);
end $$;

create or replace function public.cashflow_transactions(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  r record;
  v_type text := public.cf_text(p, 'type');
  v_class text := public.cf_text(p, 'classification');
  v_source text := public.cf_text(p, 'source');
  v_pay text := public.cf_text(p, 'payment');
  v_cat bigint := public.cf_int(p, 'category_id');
  v_q text := public.cf_text(p, 'q');
  v_review boolean := coalesce((p->>'review')::boolean, false);
  v_page integer := greatest(coalesce(public.cf_int(p, 'page'), 1), 1);
  v_size integer := least(greatest(coalesce(public.cf_int(p, 'page_size'), 25), 1), 100);
  v jsonb;
begin
  perform public.cf_require_admin();
  select * into r from public.cf_range((p->>'from')::date, (p->>'to')::date);
  if v_type is not null and v_type not in ('income','expense') then raise exception 'INVALID_FILTER:type'; end if;
  if v_class is not null and v_class not in ('real','mock') then raise exception 'INVALID_FILTER:classification'; end if;
  if v_source is not null and v_source not in ('system','system_real','system_mock','offline','expense') then raise exception 'INVALID_FILTER:source'; end if;
  if v_pay is not null and v_pay not in ('cash','bank_transfer','qris','card','other') then raise exception 'INVALID_FILTER:payment'; end if;
  if v_q is not null then v_q := '%' || replace(replace(replace(lower(v_q), '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;

  with t as (
    select 'order:' || o.id as uid, o.completed_at as at, o.order_number as ref, 'income' as ttype,
           case o.classification when 'real' then 'system_real' else 'system_mock' end as source,
           o.classification, o.payment_method as payment_raw, public.cf_pay_group(o.payment_method) as payment,
           o.total::bigint as amount, null::bigint as category_id, null::text as category_name,
           o.customer_name, null::text as vendor,
           it.txt as description,
           jsonb_build_object('id', o.id, 'order_number', o.order_number, 'status', o.status,
             'created_at', o.created_at, 'paid_at', o.paid_at, 'completed_at', o.completed_at,
             'completed_at_estimated', o.completed_at_estimated,
             'classification_source', o.classification_source, 'review', o.classification_review,
             'classification_note', o.classification_note, 'payment_env', o.payment_env,
             'subtotal', o.subtotal, 'discount', o.discount, 'delivery_fee', o.delivery_fee,
             'shipping_discount', o.shipping_discount, 'promo_code', o.promo_code,
             'guest', o.user_id is null, 'phone', o.phone, 'items', it.items) as detail
      from public.orders o
      left join lateral (
        select string_agg(oi.quantity || '× ' || oi.product_name || coalesce(' · ' || oi.variant_name, ''), ', ' order by oi.id) as txt,
               coalesce(jsonb_agg(jsonb_build_object('product_name', oi.product_name, 'variant_name', oi.variant_name,
                 'quantity', oi.quantity, 'unit_price', oi.unit_price, 'discount', 0, 'line_total', oi.line_total, 'addon', oi.addon) order by oi.id), '[]') as items
          from public.order_items oi where oi.order_id = o.id) it on true
     where o.status = 'completed' and o.completed_at >= r.r_from and o.completed_at < r.r_to
    union all
    select 'offline:' || f.id, f.order_date, coalesce(f.order_ref, 'OFF-' || f.id), 'income', 'offline',
           f.classification, f.payment_method, f.payment_method,
           f.total::bigint, null, null, f.customer_name, null,
           coalesce(it.txt, 'Penjualan offline (nominal saja)'),
           jsonb_build_object('id', f.id, 'version', f.version, 'order_ref', f.order_ref, 'source', f.source,
             'entry_mode', f.entry_mode, 'subtotal', f.subtotal, 'item_discount', f.item_discount,
             'order_discount', f.order_discount, 'extra_charge', f.extra_charge, 'notes', f.notes,
             'created_at', f.created_at, 'updated_at', f.updated_at, 'items', coalesce(it.items, '[]'))
      from public.offline_orders f
      left join lateral (
        select string_agg(i.quantity || '× ' || i.product_name || coalesce(' · ' || i.variant_name, ''), ', ' order by i.id) as txt,
               jsonb_agg(jsonb_build_object('product_id', i.product_id, 'variant_id', i.variant_id,
                 'product_name', i.product_name, 'variant_name', i.variant_name, 'quantity', i.quantity,
                 'unit_price', i.unit_price, 'discount', i.discount, 'line_total', i.line_total) order by i.id) as items
          from public.offline_order_items i where i.offline_order_id = f.id) it on true
     where f.deleted_at is null and f.order_date >= r.r_from and f.order_date < r.r_to
    union all
    select 'expense:' || e.id, e.expense_date, 'EXP-' || e.id, 'expense', 'expense',
           null, e.payment_method, e.payment_method,
           e.amount::bigint, e.category_id, e.category_name, null, e.vendor, e.description,
           jsonb_build_object('id', e.id, 'version', e.version, 'notes', e.notes, 'receipt_path', e.receipt_path,
             'created_at', e.created_at, 'updated_at', e.updated_at)
      from public.expenses e
     where e.deleted_at is null and e.expense_date >= r.r_from and e.expense_date < r.r_to
  ), f as (
    select * from t
     where classification is distinct from 'mock'          -- mock (test) orders are never listed
       and (v_type is null or ttype = v_type)
       and (v_class is null or classification = v_class)
       and (v_source is null or source = v_source or (v_source = 'system' and source in ('system_real','system_mock')))
       and (v_pay is null or payment = v_pay)
       and (v_cat is null or category_id = v_cat)
       and (not v_review or coalesce((detail->>'review')::boolean, false))
       and (v_q is null or lower(concat_ws(' ', ref, customer_name, description, vendor, category_name)) like v_q)
  )
  select jsonb_build_object(
           'total_count', (select count(*) from f),
           'page', v_page, 'page_size', v_size,
           'rows', coalesce((select jsonb_agg(to_jsonb(x) order by x.at desc, x.uid desc)
                               from (select * from f order by at desc, uid desc
                                     offset (v_page - 1) * v_size limit v_size) x), '[]'))
    into v;
  return v;
end $$;

create or replace function public.cashflow_menu_sales(p_from date, p_to date, p_scope text default 'real', p_group text default 'product')
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r record; v_total_rev bigint; v_total_qty bigint; v_rows jsonb; v_cats jsonb; v_amount jsonb;
begin
  perform public.cf_require_admin();
  if p_scope is distinct from 'real' then raise exception 'INVALID_FILTER:scope'; end if;   -- mock orders are not reported
  if p_group not in ('product','variant') then raise exception 'INVALID_FILTER:group'; end if;
  select * into r from public.cf_range(p_from, p_to);

  select coalesce(sum(revenue), 0), coalesce(sum(quantity), 0) into v_total_rev, v_total_qty
    from public.cf_menu_lines(r.r_from, r.r_to) l where l.classification = p_scope;

  select coalesce(jsonb_agg(x order by x.quantity desc, x.revenue desc, x.name), '[]') into v_rows from (
    select key,
           -- the most recent name used for this item (menu renames don't split history)
           (array_agg(product_name order by at desc))[1] as name,
           case when p_group = 'variant' then (array_agg(coalesce(variant_name, '') order by at desc))[1] end as variant,
           (array_agg(section_id order by at desc))[1] as section_id,
           coalesce((array_agg(section_name order by at desc))[1], 'Tanpa kategori') as section_name,
           sum(quantity) as quantity, sum(revenue) as revenue,
           round(sum(revenue)::numeric / nullif(sum(quantity), 0)) as avg_price,
           round(100.0 * sum(revenue) / nullif(v_total_rev, 0), 1) as share
      from (select l.*, case when p_group = 'variant' then l.product_key || '|' || lower(coalesce(l.variant_name, '')) else l.product_key end as key
              from public.cf_menu_lines(r.r_from, r.r_to) l where l.classification = p_scope) z
     group by key) x;

  select coalesce(jsonb_agg(x order by x.revenue desc, x.name), '[]') into v_cats from (
    select coalesce(section_name, 'Tanpa kategori') as name, max(section_id) as section_id,
           sum(quantity) as quantity, sum(revenue) as revenue,
           round(100.0 * sum(revenue) / nullif(v_total_rev, 0), 1) as share
      from public.cf_menu_lines(r.r_from, r.r_to) l where l.classification = p_scope
     group by coalesce(section_name, 'Tanpa kategori')) x;

  select jsonb_build_object('orders', count(*), 'value', coalesce(sum(total), 0)) into v_amount
    from public.cf_income(r.r_from, r.r_to)
   where kind = 'offline' and entry_mode = 'amount' and classification = p_scope;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'scope', p_scope, 'group', p_group,
    'total_quantity', v_total_qty, 'total_revenue', v_total_rev,
    'rows', v_rows, 'categories', v_cats, 'amount_only', v_amount,
    'insights', jsonb_build_object(
      'top_by_quantity', (select x from jsonb_array_elements(v_rows) x order by (x->>'quantity')::bigint desc, (x->>'revenue')::bigint desc limit 1),
      'top_by_revenue',  (select x from jsonb_array_elements(v_rows) x order by (x->>'revenue')::bigint desc, (x->>'quantity')::bigint desc limit 1),
      'top_category',    (select x from jsonb_array_elements(v_cats) x order by (x->>'revenue')::bigint desc limit 1)),
    'note', 'Pendapatan menu = total baris item (harga x jumlah - diskon item). Diskon tingkat pesanan, voucher dan ongkir tidak dibagi ke item, jadi angkanya bisa berbeda dari pemasukan.');
end $$;

commit;
