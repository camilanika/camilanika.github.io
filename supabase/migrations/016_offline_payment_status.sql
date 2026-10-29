-- =====================================================================
-- Migration 016: payment status for offline sales (Lunas / Belum dibayar)
-- Safe to run on the live database (and safe to run twice). Run after 015.
--
-- offline_orders.payment_status  'paid' (Lunas) | 'unpaid' (Belum dibayar)
-- offline_orders.paid_at         when the money came in (null while unpaid)
-- * Existing offline sales are paid, on their order date.
-- * Cashflow counts an offline sale only once it is paid, on its paid_at day
--   (income, items sold and menu sales). Unpaid sales are listed with their
--   order date and shown as money still owed; they never count as income.
-- * cashflow_mark_offline_paid marks one as paid (date + payment method), audited.
-- * cashflow_transactions gets a customer filter (p.customer, exact name, any case);
--   cashflow_customers lists the customers of a period for that filter.
-- =====================================================================
begin;

alter table public.offline_orders
  add column if not exists payment_status text not null default 'paid',
  add column if not exists paid_at timestamptz;
alter table public.offline_orders drop constraint if exists offline_orders_payment_status_check;
alter table public.offline_orders add constraint offline_orders_payment_status_check check (payment_status in ('paid','unpaid'));
update public.offline_orders set paid_at = order_date where payment_status = 'paid' and paid_at is null;
alter table public.offline_orders drop constraint if exists offline_orders_paid_at_check;
alter table public.offline_orders add constraint offline_orders_paid_at_check check ((payment_status = 'paid') = (paid_at is not null));
create index if not exists offline_orders_paid_idx on public.offline_orders (paid_at) where deleted_at is null;
create index if not exists offline_orders_unpaid_idx on public.offline_orders (payment_status) where deleted_at is null and payment_status = 'unpaid';

create or replace function public.cf_income(r_from timestamptz, r_to timestamptz)
returns table (kind text, ref_id text, at timestamptz, classification text, total bigint, entry_mode text)
language sql stable security definer set search_path = public as $$
  select 'system', o.id::text, o.completed_at, o.classification, o.total::bigint, 'items'
    from public.orders o
   where o.status = 'completed' and o.completed_at >= r_from and o.completed_at < r_to
  union all
  -- offline sales count when the money is received (paid_at); unpaid ones are not income yet
  select 'offline', f.id::text, f.paid_at, f.classification, f.total::bigint, f.entry_mode
    from public.offline_orders f
   where f.deleted_at is null and f.payment_status = 'paid' and f.paid_at >= r_from and f.paid_at < r_to;
$$;
revoke execute on function public.cf_income(timestamptz, timestamptz) from public, anon, authenticated;

create or replace function public.cf_menu_lines(r_from timestamptz, r_to timestamptz)
returns table (kind text, classification text, at timestamptz, product_key text, product_id bigint,
               product_name text, variant_name text, section_id bigint, section_name text,
               quantity bigint, revenue bigint)
language sql stable security definer set search_path = public as $$
  select 'system', o.classification, o.completed_at,
         coalesce('p' || oi.product_id, 'n:' || lower(oi.product_name)), oi.product_id,
         oi.product_name, oi.variant_name,
         p.section_id, s.name,
         oi.quantity::bigint, oi.line_total::bigint
    from public.orders o
    join public.order_items oi on oi.order_id = o.id
    left join public.products p on p.id = oi.product_id
    left join public.menu_sections s on s.id = p.section_id
   where o.status = 'completed' and o.completed_at >= r_from and o.completed_at < r_to
  union all
  select 'offline', f.classification, f.paid_at,
         coalesce('p' || i.product_id, 'n:' || lower(i.product_name)), i.product_id,
         i.product_name, i.variant_name,
         coalesce(p.section_id, i.section_id), coalesce(s.name, i.section_name),
         i.quantity::bigint, i.line_total::bigint
    from public.offline_orders f
    join public.offline_order_items i on i.offline_order_id = f.id
    left join public.products p on p.id = i.product_id
    left join public.menu_sections s on s.id = p.section_id
   where f.deleted_at is null and f.entry_mode = 'items' and f.payment_status = 'paid' and f.paid_at >= r_from and f.paid_at < r_to;
$$;
revoke execute on function public.cf_menu_lines(timestamptz, timestamptz) from public, anon, authenticated;

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
    'refunds_tracked', false,
    -- offline sales still waiting for payment (all dates): not income yet
    'unpaid_offline_orders', (select count(*) from public.offline_orders f
                               where f.deleted_at is null and f.payment_status = 'unpaid' and f.classification = 'real'),
    'unpaid_offline_value', (select coalesce(sum(f.total), 0) from public.offline_orders f
                               where f.deleted_at is null and f.payment_status = 'unpaid' and f.classification = 'real'));
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
  v_pstat text := public.cf_text(p, 'payment_status');
  v_cust text := lower(public.cf_text(p, 'customer'));
  v_page integer := greatest(coalesce(public.cf_int(p, 'page'), 1), 1);
  v_size integer := least(greatest(coalesce(public.cf_int(p, 'page_size'), 25), 1), 100);
  v jsonb;
begin
  perform public.cf_require_admin();
  select * into r from public.cf_range((p->>'from')::date, (p->>'to')::date);
  if v_type is not null and v_type not in ('income','expense') then raise exception 'INVALID_FILTER:type'; end if;
  if v_class is not null and v_class not in ('real','mock') then raise exception 'INVALID_FILTER:classification'; end if;
  if v_source is not null and v_source not in ('system','system_real','system_mock','offline','expense') then raise exception 'INVALID_FILTER:source'; end if;
  if v_pstat is not null and v_pstat not in ('paid','unpaid') then raise exception 'INVALID_FILTER:payment_status'; end if;
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
    select 'offline:' || f.id, coalesce(f.paid_at, f.order_date), coalesce(f.order_ref, 'OFF-' || f.id), 'income', 'offline',
           f.classification, f.payment_method, f.payment_method,
           f.total::bigint, null, null, f.customer_name, null,
           coalesce(it.txt, 'Penjualan offline (nominal saja)'),
           jsonb_build_object('id', f.id, 'version', f.version, 'order_ref', f.order_ref, 'source', f.source,
             'payment_status', f.payment_status, 'paid_at', f.paid_at, 'order_date', f.order_date,
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
     where f.deleted_at is null and coalesce(f.paid_at, f.order_date) >= r.r_from and coalesce(f.paid_at, f.order_date) < r.r_to
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
       and (v_pstat is null or coalesce(detail->>'payment_status', 'paid') = v_pstat)
       and (v_cust is null or lower(trim(customer_name)) = v_cust)
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

create or replace function public.cashflow_save_offline_order(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id bigint := public.cf_int(p, 'id');
  v_token uuid;
  v_old public.offline_orders;
  v_row public.offline_orders;
  v_date timestamptz;
  v_ref text := public.cf_text(p, 'order_ref');
  v_source text := coalesce(public.cf_text(p, 'source'), 'walk_in');
  v_pay text := public.cf_text(p, 'payment_method');
  v_class text := coalesce(public.cf_text(p, 'classification'), 'real');
  v_mode text := coalesce(public.cf_text(p, 'entry_mode'), 'items');
  v_order_disc integer := coalesce(public.cf_int(p, 'order_discount'), 0);
  v_extra integer := coalesce(public.cf_int(p, 'extra_charge'), 0);
  v_expected integer := public.cf_int(p, 'expected_total');
  v_sub bigint := 0; v_item_disc bigint := 0; v_total bigint;
  it jsonb; v_q integer; v_price integer; v_disc integer;
  v_vid bigint; v_vname text; v_vprice integer; v_pid bigint; v_pname text; v_sid bigint; v_sname text; v_prod_id bigint;
  v_lines jsonb := '[]';
  v_before jsonb;
  v_pstat text := coalesce(public.cf_text(p, 'payment_status'), 'paid');
  v_paid_at timestamptz;
begin
  perform public.cf_require_admin();

  begin v_token := (p->>'client_token')::uuid; exception when others then raise exception 'INVALID_CLIENT_TOKEN'; end;
  begin v_date := (p->>'order_date')::timestamptz; exception when others then raise exception 'INVALID_DATE'; end;
  if v_date is null then raise exception 'DATE_REQUIRED'; end if;
  if v_date > now() + interval '1 day' then raise exception 'DATE_IN_FUTURE'; end if;
  if v_date < '2020-01-01' then raise exception 'INVALID_DATE'; end if;
  if v_source not in ('walk_in','whatsapp','phone','social_media','other') then raise exception 'INVALID_SOURCE'; end if;
  if v_pstat not in ('paid','unpaid') then raise exception 'INVALID_PAYMENT_STATUS'; end if;
  if v_pstat = 'paid' then
    begin v_paid_at := coalesce((p->>'paid_at')::timestamptz, v_date); exception when others then raise exception 'INVALID_DATE'; end;
    if v_paid_at > now() + interval '1 day' then raise exception 'DATE_IN_FUTURE'; end if;
    if v_paid_at < v_date - interval '1 day' then raise exception 'PAID_BEFORE_ORDER'; end if;
  end if;
  if v_pay is null or v_pay not in ('cash','bank_transfer','qris','other') then raise exception 'INVALID_PAYMENT_METHOD'; end if;
  if v_class not in ('real','mock') then raise exception 'INVALID_CLASSIFICATION'; end if;
  if v_mode not in ('items','amount') then raise exception 'INVALID_ENTRY_MODE'; end if;
  if v_order_disc < 0 or v_extra < 0 then raise exception 'NEGATIVE_AMOUNT'; end if;
  if v_ref is not null and length(v_ref) > 60 then raise exception 'REF_TOO_LONG'; end if;
  -- an online order number recorded again here would be counted twice
  if v_ref is not null and exists (select 1 from public.orders where lower(order_number) = lower(v_ref)) then
    raise exception 'REF_IS_ONLINE_ORDER';
  end if;

  if v_mode = 'amount' then
    if jsonb_array_length(coalesce(p->'items', '[]')) > 0 then raise exception 'AMOUNT_MODE_HAS_ITEMS'; end if;
    v_total := public.cf_int(p, 'amount');
    if v_total is null or v_total <= 0 then raise exception 'AMOUNT_MUST_BE_POSITIVE'; end if;
    if v_order_disc > 0 or v_extra > 0 then raise exception 'AMOUNT_MODE_NO_ADJUSTMENTS'; end if;
    v_sub := 0;
  else
    if jsonb_typeof(p->'items') is distinct from 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'ITEMS_REQUIRED'; end if;
    if jsonb_array_length(p->'items') > 100 then raise exception 'TOO_MANY_ITEMS'; end if;
    for it in select * from jsonb_array_elements(p->'items') loop
      v_q := public.cf_int(it, 'quantity');
      if v_q is null or v_q < 1 or v_q > 10000 then raise exception 'INVALID_QUANTITY'; end if;
      v_disc := coalesce(public.cf_int(it, 'discount'), 0);
      v_price := public.cf_int(it, 'unit_price');
      v_vid := null; v_vname := null; v_vprice := null; v_pid := null; v_pname := null; v_sid := null; v_sname := null;
      v_prod_id := public.cf_int(it, 'product_id');
      if public.cf_int(it, 'variant_id') is not null then
        select v.id, v.name, v.price, v.product_id into v_vid, v_vname, v_vprice, v_prod_id
          from public.product_variants v where v.id = public.cf_int(it, 'variant_id');
        if v_vid is null then raise exception 'VARIANT_NOT_FOUND'; end if;
        v_price := coalesce(v_price, v_vprice);   -- menu price unless a different price was charged
      end if;
      if v_prod_id is not null then
        select pr.id, pr.name, pr.section_id, s.name into v_pid, v_pname, v_sid, v_sname
          from public.products pr left join public.menu_sections s on s.id = pr.section_id where pr.id = v_prod_id;
        if v_pid is null then raise exception 'PRODUCT_NOT_FOUND'; end if;
      elsif public.cf_text(it, 'product_name') is null then
        raise exception 'ITEM_NAME_REQUIRED';
      end if;
      if v_price is null then raise exception 'PRICE_REQUIRED'; end if;
      if v_price < 0 or v_price > 100000000 then raise exception 'INVALID_PRICE'; end if;
      if v_disc < 0 or v_disc > v_price::bigint * v_q then raise exception 'INVALID_ITEM_DISCOUNT'; end if;
      v_sub := v_sub + v_price::bigint * v_q;
      v_item_disc := v_item_disc + v_disc;
      v_lines := v_lines || jsonb_build_object(
        'product_id', v_pid, 'variant_id', v_vid,
        'product_name', coalesce(v_pname, left(public.cf_text(it, 'product_name'), 120)),
        'variant_name', coalesce(v_vname, left(public.cf_text(it, 'variant_name'), 120)),
        'section_id', v_sid, 'section_name', v_sname,
        'quantity', v_q, 'unit_price', v_price, 'discount', v_disc, 'line_total', v_price::bigint * v_q - v_disc);
    end loop;
    if v_order_disc > v_sub - v_item_disc then raise exception 'ORDER_DISCOUNT_TOO_LARGE'; end if;
    v_total := v_sub - v_item_disc - v_order_disc + v_extra;
  end if;
  if v_total > 1000000000 then raise exception 'TOTAL_TOO_LARGE'; end if;
  if v_expected is not null and v_expected <> v_total then raise exception 'TOTAL_MISMATCH:%', v_total; end if;

  if v_id is null then
    if v_token is null then raise exception 'CLIENT_TOKEN_REQUIRED'; end if;
    -- same submission sent twice (double click, retry): return the saved one
    select * into v_row from public.offline_orders where client_token = v_token;
    if found then return jsonb_build_object('id', v_row.id, 'version', v_row.version, 'total', v_row.total, 'duplicate', true); end if;
    begin
      insert into public.offline_orders (client_token, order_ref, order_date, customer_name, source, payment_method,
          classification, entry_mode, subtotal, item_discount, order_discount, extra_charge, total, notes, created_by, updated_by,
          payment_status, paid_at)
      values (v_token, v_ref, v_date, left(public.cf_text(p, 'customer_name'), 120), v_source, v_pay,
          v_class, v_mode, v_sub, v_item_disc, v_order_disc, v_extra, v_total, left(public.cf_text(p, 'notes'), 1000), auth.uid(), auth.uid(),
          v_pstat, v_paid_at)
      returning * into v_row;
    exception when unique_violation then
      if exists (select 1 from public.offline_orders where client_token = v_token) then
        select * into v_row from public.offline_orders where client_token = v_token;
        return jsonb_build_object('id', v_row.id, 'version', v_row.version, 'total', v_row.total, 'duplicate', true);
      end if;
      raise exception 'DUPLICATE_REF';
    end;
  else
    select * into v_old from public.offline_orders where id = v_id for update;
    if not found or v_old.deleted_at is not null then raise exception 'RECORD_NOT_FOUND'; end if;
    if public.cf_int(p, 'version') is distinct from v_old.version then raise exception 'STALE_RECORD'; end if;
    v_before := to_jsonb(v_old) || jsonb_build_object('items',
      (select coalesce(jsonb_agg(to_jsonb(i) order by i.id), '[]') from public.offline_order_items i where i.offline_order_id = v_id));
    begin
      update public.offline_orders
         set order_ref = v_ref, order_date = v_date, customer_name = left(public.cf_text(p, 'customer_name'), 120),
             source = v_source, payment_method = v_pay, classification = v_class, entry_mode = v_mode,
             subtotal = v_sub, item_discount = v_item_disc, order_discount = v_order_disc, extra_charge = v_extra,
             total = v_total, notes = left(public.cf_text(p, 'notes'), 1000), version = version + 1, updated_by = auth.uid(),
             payment_status = v_pstat, paid_at = v_paid_at
       where id = v_id returning * into v_row;
    exception when unique_violation then raise exception 'DUPLICATE_REF';
    end;
    delete from public.offline_order_items where offline_order_id = v_id;
  end if;

  insert into public.offline_order_items (offline_order_id, product_id, variant_id, product_name, variant_name,
      section_id, section_name, quantity, unit_price, discount, line_total)
  select v_row.id, (l->>'product_id')::bigint, (l->>'variant_id')::bigint, l->>'product_name', l->>'variant_name',
         (l->>'section_id')::bigint, l->>'section_name', (l->>'quantity')::int, (l->>'unit_price')::int,
         (l->>'discount')::int, (l->>'line_total')::int
    from jsonb_array_elements(v_lines) l;

  perform public.cf_log('offline_order', v_row.id::text, case when v_id is null then 'create' else 'update' end,
    v_before, to_jsonb(v_row) || jsonb_build_object('items', v_lines));
  return jsonb_build_object('id', v_row.id, 'version', v_row.version, 'total', v_row.total, 'duplicate', false);
end $$;

-- customers in a period (online orders + offline sales, no test orders), for the Pelanggan filter
create or replace function public.cashflow_customers(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  perform public.cf_require_admin();
  select * into r from public.cf_range(p_from, p_to);
  return coalesce((
    select jsonb_agg(jsonb_build_object('name', name, 'orders', n) order by lower(name))
      from (select (array_agg(trim(customer_name) order by at desc))[1] as name, count(*) as n
              from (select o.customer_name, o.completed_at as at from public.orders o
                     where o.status = 'completed' and o.classification = 'real'
                       and o.completed_at >= r.r_from and o.completed_at < r.r_to
                    union all
                    select f.customer_name, coalesce(f.paid_at, f.order_date) from public.offline_orders f
                     where f.deleted_at is null and f.classification = 'real'
                       and coalesce(f.paid_at, f.order_date) >= r.r_from and coalesce(f.paid_at, f.order_date) < r.r_to) x
             where nullif(trim(customer_name), '') is not null
             group by lower(trim(customer_name))) c), '[]');
end $$;
revoke execute on function public.cashflow_customers(date, date) from public, anon;
grant execute on function public.cashflow_customers(date, date) to authenticated;

-- mark an unpaid offline sale as paid (Lunas)
create or replace function public.cashflow_mark_offline_paid(p_id bigint, p_version integer, p_paid_at timestamptz, p_payment_method text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.offline_orders; v_new public.offline_orders;
begin
  perform public.cf_require_admin();
  select * into v from public.offline_orders where id = p_id for update;
  if not found or v.deleted_at is not null then raise exception 'RECORD_NOT_FOUND'; end if;
  if p_version is distinct from v.version then raise exception 'STALE_RECORD'; end if;
  if v.payment_status = 'paid' then raise exception 'ALREADY_PAID'; end if;
  if p_paid_at is null then raise exception 'DATE_REQUIRED'; end if;
  if p_paid_at > now() + interval '1 day' then raise exception 'DATE_IN_FUTURE'; end if;
  if p_paid_at < v.order_date - interval '1 day' then raise exception 'PAID_BEFORE_ORDER'; end if;
  if p_payment_method is null or p_payment_method not in ('cash','bank_transfer','qris','other') then raise exception 'INVALID_PAYMENT_METHOD'; end if;
  update public.offline_orders
     set payment_status = 'paid', paid_at = p_paid_at, payment_method = p_payment_method, version = version + 1, updated_by = auth.uid()
   where id = p_id returning * into v_new;
  perform public.cf_log('offline_order', p_id::text, 'paid', to_jsonb(v), to_jsonb(v_new));
  return jsonb_build_object('id', v_new.id, 'version', v_new.version, 'paid_at', v_new.paid_at);
end $$;
revoke execute on function public.cashflow_mark_offline_paid(bigint, integer, timestamptz, text) from public, anon;
grant execute on function public.cashflow_mark_offline_paid(bigint, integer, timestamptz, text) to authenticated;

commit;
