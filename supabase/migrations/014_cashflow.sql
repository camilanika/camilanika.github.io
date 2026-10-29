-- =====================================================================
-- Migration 014: Cashflow Summary (income, expenses, real vs mock orders, menu sales)
-- Safe to run on the live database (and safe to run twice).
--
-- How records are told apart
--   orders (online, system-generated)
--     classification        'real' | 'mock'   (mock = test / demo, never counted as income)
--     classification_source 'auto'      set from the Midtrans environment (see below)
--                           'admin'     an admin chose it in Cashflow Summary
--                           'migration' set by this script for orders that already existed
--     classification_review true = needs an admin to confirm it (shown as "Perlu ditinjau")
--     payment_env           'sandbox' | 'production', reported by the create-payment /
--                           midtrans-webhook Edge Functions (tag_order_payment_env)
--     completed_at          when the order became 'completed' = the sales recognition date
--   New orders are classified automatically: Midtrans Sandbox -> mock, Production -> real.
--   If the Edge Function hasn't reported the environment, shop_settings.payments_mode
--   (default 'sandbox') decides. Switch it to 'production' in Cashflow Summary when you go live.
--
--   offline_orders (+ offline_order_items)  manual walk-in / WhatsApp / phone sales.
--     Separate table, so they can never be mistaken for (or double-counted with) online orders.
--     entry_mode 'items' (menu lines) or 'amount' (amount only: counts as income, not in menu stats).
--   expenses (+ expense_categories)         business costs, never stored as negative income.
--   cashflow_audit                          who created / changed / deleted what, with before/after.
--   Offline orders and expenses are soft-deleted (deleted_at), never removed.
--
-- Rules (all calculated here, in the database)
--   Real Order Income    = sum(total) of orders with status 'completed', classification 'real',
--                          completed_at in the period
--   Offline Order Income = sum(total) of offline orders classified 'real', order_date in the period
--   Total Income         = Real Order Income + Offline Order Income
--   Mock Order Value     = completed mock online orders + mock offline orders (shown separately only)
--   Total Expenses       = sum(amount) of expenses, expense_date in the period
--   Net Cashflow         = Total Income - Total Expenses   (recorded cash in minus cash out, not profit)
--   Periods are calendar days in Asia/Jakarta (WIB): [from 00:00, to+1 00:00).
--   Pending / paid-but-not-completed / cancelled / expired / failed orders are never income.
--   A paid order cancelled from Pesanan (refunded in Midtrans) has status 'cancelled', so it is
--   not counted. The shop has no partial-refund records; see SHOP_SETUP.md.
-- =====================================================================
begin;

-- ---------------------------------------------------------------- run-once markers
create table if not exists public.cashflow_meta (
  key     text primary key,
  ran_at  timestamptz not null default now(),
  info    jsonb
);
alter table public.cashflow_meta enable row level security;
revoke all on public.cashflow_meta from anon, authenticated;

-- ---------------------------------------------------------------- settings
alter table public.shop_settings
  add column if not exists payments_mode text not null default 'sandbox';
alter table public.shop_settings drop constraint if exists shop_settings_payments_mode_check;
alter table public.shop_settings add constraint shop_settings_payments_mode_check
  check (payments_mode in ('sandbox','production'));

-- ---------------------------------------------------------------- orders: classification + completion date
alter table public.orders
  add column if not exists classification         text not null default 'real',
  add column if not exists classification_source  text not null default 'auto',
  add column if not exists classification_review  boolean not null default false,
  add column if not exists classification_note    text,
  add column if not exists payment_env            text,
  add column if not exists completed_at           timestamptz,
  add column if not exists completed_at_estimated boolean not null default false;
alter table public.orders drop constraint if exists orders_classification_check;
alter table public.orders add constraint orders_classification_check check (classification in ('real','mock'));
alter table public.orders drop constraint if exists orders_classification_source_check;
alter table public.orders add constraint orders_classification_source_check check (classification_source in ('auto','admin','migration'));
alter table public.orders drop constraint if exists orders_payment_env_check;
alter table public.orders add constraint orders_payment_env_check check (payment_env is null or payment_env in ('sandbox','production'));

create index if not exists orders_cashflow_idx on public.orders (status, completed_at);
create index if not exists orders_classification_idx on public.orders (classification, completed_at);

-- classification for a new or re-tagged order
create or replace function public.cf_auto_classification(p_env text)
returns text language sql stable security definer set search_path = public as $$
  select case when coalesce(p_env, (select payments_mode from public.shop_settings where id = 1), 'sandbox') = 'production'
              then 'real' else 'mock' end;
$$;
revoke execute on function public.cf_auto_classification(text) from public, anon, authenticated;

create or replace function public.trg_cf_order_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.classification_source = 'auto' then
    new.classification := public.cf_auto_classification(new.payment_env);
  end if;
  if new.status = 'completed' and new.completed_at is null then new.completed_at := now(); end if;
  return new;
end $$;
drop trigger if exists trg_orders_cf_insert on public.orders;
create trigger trg_orders_cf_insert before insert on public.orders
  for each row execute function public.trg_cf_order_insert();

create or replace function public.trg_cf_order_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- recognition date: the moment the order first becomes 'completed'
  if new.status = 'completed' and old.status is distinct from 'completed' and new.completed_at is null then
    new.completed_at := now(); new.completed_at_estimated := false;
  end if;
  -- Midtrans environment reported later: re-derive an automatic classification
  if new.payment_env is distinct from old.payment_env and new.classification_source = 'auto' then
    new.classification := public.cf_auto_classification(new.payment_env);
  end if;
  return new;
end $$;
drop trigger if exists trg_orders_cf_update on public.orders;
create trigger trg_orders_cf_update before update on public.orders
  for each row execute function public.trg_cf_order_update();

-- Called by the Edge Functions (service role) with the Midtrans environment they used.
create or replace function public.tag_order_payment_env(p_order_number text, p_env text)
returns text language plpgsql security definer set search_path = public as $$
declare v_class text;
begin
  if p_env is null or p_env not in ('sandbox','production') then raise exception 'INVALID_ENV'; end if;
  update public.orders set payment_env = p_env
   where order_number = p_order_number and payment_env is distinct from p_env;
  select classification into v_class from public.orders where order_number = p_order_number;
  return v_class;
end $$;
revoke execute on function public.tag_order_payment_env(text, text) from public, anon, authenticated;
grant execute on function public.tag_order_payment_env(text, text) to service_role;

-- ---------------------------------------------------------------- audit log
create table if not exists public.cashflow_audit (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  actor       uuid references auth.users(id) on delete set null,
  entity      text not null check (entity in ('order','offline_order','expense','expense_category','settings')),
  entity_id   text not null,
  action      text not null,          -- create, update, delete, classify, review, payments_mode
  before      jsonb,
  after       jsonb
);
create index if not exists cashflow_audit_entity_idx on public.cashflow_audit (entity, entity_id, at desc);
alter table public.cashflow_audit enable row level security;
drop policy if exists cashflow_audit_admin_read on public.cashflow_audit;
create policy cashflow_audit_admin_read on public.cashflow_audit for select to authenticated using (public.is_admin());
revoke insert, update, delete on public.cashflow_audit from anon, authenticated;

create or replace function public.cf_log(p_entity text, p_id text, p_action text, p_before jsonb, p_after jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.cashflow_audit (actor, entity, entity_id, action, before, after)
  values (auth.uid(), p_entity, p_id, p_action, p_before, p_after);
$$;
revoke execute on function public.cf_log(text, text, text, jsonb, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------- backfill existing orders (runs once)
-- Every order placed so far went through Midtrans SANDBOX (js/config.js has always had
-- MIDTRANS_IS_PRODUCTION: false and ONLINE_PAYMENT: "test"), so no real money was taken.
-- They are marked MOCK and flagged for review; an admin can switch any of them to Real.
-- If you run this after going live, put the go-live moment in v_live_since: orders from then on
-- become REAL (still flagged for review).
do $$
declare
  v_live_since timestamptz := null;   -- e.g. '2026-11-15 09:00+07'
  v_n integer;
begin
  if exists (select 1 from public.cashflow_meta where key = '014_orders_backfill') then return; end if;

  -- One statement, with the updated_at trigger paused: the backfill must not overwrite each order's
  -- real "last changed" time, which is the best record of when older orders were completed.
  alter table public.orders disable trigger trg_orders_updated;
  update public.orders
     set classification = case when v_live_since is not null and created_at >= v_live_since then 'real' else 'mock' end,
         classification_source = 'migration',
         classification_review = true,
         classification_note = case when v_live_since is not null and created_at >= v_live_since
           then 'Dibuat setelah Midtrans Production aktif. Pastikan ini pembelian asli.'
           else 'Dibuat saat pembayaran Midtrans masih Sandbox (tes), sebelum Cashflow Summary ada. Ubah ke Real hanya jika ini pembelian asli.' end,
         -- completion date for orders completed before this script (marked as an estimate)
         completed_at = case when status = 'completed' and completed_at is null then updated_at else completed_at end,
         completed_at_estimated = (status = 'completed' and completed_at is null) or completed_at_estimated;
  get diagnostics v_n = row_count;
  alter table public.orders enable trigger trg_orders_updated;

  insert into public.cashflow_meta (key, info) values ('014_orders_backfill', jsonb_build_object('orders', v_n, 'live_since', v_live_since));
end $$;

-- ---------------------------------------------------------------- expense categories
create table if not exists public.expense_categories (
  id          bigint generated always as identity primary key,
  name        text not null,
  is_default  boolean not null default false,
  is_active   boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index if not exists expense_categories_name_uq on public.expense_categories (lower(name));
drop trigger if exists trg_expense_categories_updated on public.expense_categories;
create trigger trg_expense_categories_updated before update on public.expense_categories
  for each row execute function public.set_updated_at();

insert into public.expense_categories (name, is_default, sort_order)
select n, true, o from (values
  ('Raw Materials / Ingredients', 1), ('Packaging', 2), ('Equipment', 3), ('Utilities', 4),
  ('Delivery / Transportation', 5), ('Marketing / Promotion', 6), ('Platform Fees / Commissions', 7),
  ('Employee / Labor Costs', 8), ('Maintenance', 9), ('Rent', 10), ('Other', 11)) d(n, o)
on conflict do nothing;

-- ---------------------------------------------------------------- expenses
create table if not exists public.expenses (
  id              bigint generated always as identity primary key,
  client_token    uuid not null unique,            -- one per form submission: a double click saves once
  expense_date    timestamptz not null,
  description     text not null check (length(trim(description)) between 1 and 200),
  category_id     bigint references public.expense_categories(id) on delete set null,
  category_name   text not null,                   -- snapshot: renaming a category keeps history
  amount          integer not null check (amount > 0 and amount <= 1000000000),
  payment_method  text not null check (payment_method in ('cash','bank_transfer','qris','other')),
  vendor          text,
  receipt_path    text,                            -- file in the private 'expense-receipts' bucket
  notes           text,
  version         integer not null default 1,
  created_by      uuid references auth.users(id) on delete set null,
  updated_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz,
  deleted_by      uuid references auth.users(id) on delete set null
);
create index if not exists expenses_date_idx on public.expenses (expense_date) where deleted_at is null;
create index if not exists expenses_category_idx on public.expenses (category_id);
drop trigger if exists trg_expenses_updated on public.expenses;
create trigger trg_expenses_updated before update on public.expenses
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------- offline orders
create table if not exists public.offline_orders (
  id              bigint generated always as identity primary key,
  client_token    uuid not null unique,
  order_ref       text,                            -- receipt / note number (optional)
  order_date      timestamptz not null,
  customer_name   text,
  source          text not null check (source in ('walk_in','whatsapp','phone','social_media','other')),
  payment_method  text not null check (payment_method in ('cash','bank_transfer','qris','other')),
  classification  text not null default 'real' check (classification in ('real','mock')),
  entry_mode      text not null check (entry_mode in ('items','amount')),
  subtotal        integer not null default 0 check (subtotal >= 0),       -- sum of qty x unit price
  item_discount   integer not null default 0 check (item_discount >= 0),  -- sum of line discounts
  order_discount  integer not null default 0 check (order_discount >= 0),
  extra_charge    integer not null default 0 check (extra_charge >= 0),   -- e.g. ongkir paid by the customer
  total           integer not null check (total >= 0 and total <= 1000000000),
  notes           text,
  version         integer not null default 1,
  created_by      uuid references auth.users(id) on delete set null,
  updated_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz,
  deleted_by      uuid references auth.users(id) on delete set null,
  check (entry_mode = 'items' or (subtotal = 0 and item_discount = 0 and order_discount = 0 and extra_charge = 0 and total > 0)),
  check (entry_mode = 'amount' or total = subtotal - item_discount - order_discount + extra_charge)
);
create index if not exists offline_orders_date_idx on public.offline_orders (order_date) where deleted_at is null;
create unique index if not exists offline_orders_ref_uq on public.offline_orders (lower(order_ref))
  where deleted_at is null and order_ref is not null;
drop trigger if exists trg_offline_orders_updated on public.offline_orders;
create trigger trg_offline_orders_updated before update on public.offline_orders
  for each row execute function public.set_updated_at();

create table if not exists public.offline_order_items (
  id                bigint generated always as identity primary key,
  offline_order_id  bigint not null references public.offline_orders(id) on delete cascade,
  product_id        bigint references public.products(id) on delete set null,
  variant_id        bigint references public.product_variants(id) on delete set null,
  product_name      text not null,       -- snapshots, so menu edits never change history
  variant_name      text,
  section_id        bigint,
  section_name      text,
  quantity          integer not null check (quantity between 1 and 10000),
  unit_price        integer not null check (unit_price between 0 and 100000000),
  discount          integer not null default 0 check (discount >= 0),
  line_total        integer not null,
  check (discount <= unit_price * quantity),
  check (line_total = unit_price * quantity - discount)
);
create index if not exists offline_order_items_order_idx on public.offline_order_items (offline_order_id);
create index if not exists offline_order_items_product_idx on public.offline_order_items (product_id);

-- ---------------------------------------------------------------- security: admins read, all writes via functions
alter table public.expense_categories  enable row level security;
alter table public.expenses            enable row level security;
alter table public.offline_orders      enable row level security;
alter table public.offline_order_items enable row level security;
drop policy if exists expense_categories_admin_read on public.expense_categories;
create policy expense_categories_admin_read on public.expense_categories for select to authenticated using (public.is_admin());
drop policy if exists expenses_admin_read on public.expenses;
create policy expenses_admin_read on public.expenses for select to authenticated using (public.is_admin());
drop policy if exists offline_orders_admin_read on public.offline_orders;
create policy offline_orders_admin_read on public.offline_orders for select to authenticated using (public.is_admin());
drop policy if exists offline_order_items_admin_read on public.offline_order_items;
create policy offline_order_items_admin_read on public.offline_order_items for select to authenticated using (public.is_admin());
revoke insert, update, delete on public.expense_categories, public.expenses, public.offline_orders, public.offline_order_items
  from anon, authenticated;
-- payments_mode decides how new orders are classified, so every change is logged
create or replace function public.trg_cf_payments_mode()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.payments_mode is distinct from old.payments_mode then
    perform public.cf_log('settings', 'payments_mode', 'payments_mode', to_jsonb(old.payments_mode), to_jsonb(new.payments_mode));
  end if;
  return new;
end $$;
revoke execute on function public.trg_cf_payments_mode() from public, anon, authenticated;
drop trigger if exists trg_shop_settings_cf_mode on public.shop_settings;
create trigger trg_shop_settings_cf_mode after update on public.shop_settings
  for each row execute function public.trg_cf_payments_mode();

-- receipts: private bucket, admins only
insert into storage.buckets (id, name, public) values ('expense-receipts', 'expense-receipts', false)
  on conflict (id) do nothing;
drop policy if exists expense_receipts_admin_select on storage.objects;
create policy expense_receipts_admin_select on storage.objects for select to authenticated
  using (bucket_id = 'expense-receipts' and public.is_admin());
drop policy if exists expense_receipts_admin_insert on storage.objects;
create policy expense_receipts_admin_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'expense-receipts' and public.is_admin());
drop policy if exists expense_receipts_admin_delete on storage.objects;
create policy expense_receipts_admin_delete on storage.objects for delete to authenticated
  using (bucket_id = 'expense-receipts' and public.is_admin());

-- ---------------------------------------------------------------- helpers
create or replace function public.cf_require_admin()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
end $$;
revoke execute on function public.cf_require_admin() from public, anon, authenticated;

-- calendar days in WIB -> [start, end)
create or replace function public.cf_range(p_from date, p_to date, out r_from timestamptz, out r_to timestamptz)
language plpgsql immutable as $$
begin
  if p_from is null or p_to is null then raise exception 'DATE_REQUIRED'; end if;
  if p_to < p_from then raise exception 'DATE_RANGE_INVALID'; end if;
  if p_to - p_from > 3700 then raise exception 'DATE_RANGE_TOO_LONG'; end if;
  r_from := p_from::timestamp at time zone 'Asia/Jakarta';
  r_to   := (p_to + 1)::timestamp at time zone 'Asia/Jakarta';
end $$;
revoke execute on function public.cf_range(date, date) from public, anon, authenticated;

-- Midtrans payment types grouped like the offline choices
create or replace function public.cf_pay_group(m text)
returns text language sql immutable as $$
  select case when m is null then 'other'
              when m = 'cash' then 'cash'
              when m in ('bank_transfer','echannel','permata','bca_va','bni_va','bri_va','cimb_va','other_va') then 'bank_transfer'
              when m in ('qris','gopay','shopeepay','other_qris','dana','ovo') then 'qris'
              when m = 'credit_card' then 'card'
              else 'other' end;
$$;

-- strict whole-number reader for money / quantities: rejects decimals, text, negatives in disguise
create or replace function public.cf_int(p jsonb, k text, p_default integer default null)
returns integer language plpgsql immutable as $$
declare v jsonb := p -> k;
begin
  if v is null or v = 'null'::jsonb or (jsonb_typeof(v) = 'string' and trim(v #>> '{}') = '') then return p_default; end if;
  if jsonb_typeof(v) = 'number' and (v #>> '{}') ~ '^-?\d+$' then return (v #>> '{}')::integer; end if;
  if jsonb_typeof(v) = 'string' and trim(v #>> '{}') ~ '^-?\d+$' then return trim(v #>> '{}')::integer; end if;
  raise exception 'INVALID_NUMBER:%', k;
exception when numeric_value_out_of_range then raise exception 'NUMBER_TOO_LARGE:%', k;
end $$;

create or replace function public.cf_text(p jsonb, k text)
returns text language sql immutable as $$ select nullif(trim(p ->> k), '') $$;

-- ---------------------------------------------------------------- income lines (one place for every report)
-- every eligible income record in a period, real and mock
create or replace function public.cf_income(r_from timestamptz, r_to timestamptz)
returns table (kind text, ref_id text, at timestamptz, classification text, total bigint, entry_mode text)
language sql stable security definer set search_path = public as $$
  select 'system', o.id::text, o.completed_at, o.classification, o.total::bigint, 'items'
    from public.orders o
   where o.status = 'completed' and o.completed_at >= r_from and o.completed_at < r_to
  union all
  select 'offline', f.id::text, f.order_date, f.classification, f.total::bigint, f.entry_mode
    from public.offline_orders f
   where f.deleted_at is null and f.order_date >= r_from and f.order_date < r_to;
$$;
revoke execute on function public.cf_income(timestamptz, timestamptz) from public, anon, authenticated;

-- every eligible menu line in a period (amount-only offline orders have none)
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
  select 'offline', f.classification, f.order_date,
         coalesce('p' || i.product_id, 'n:' || lower(i.product_name)), i.product_id,
         i.product_name, i.variant_name,
         coalesce(p.section_id, i.section_id), coalesce(s.name, i.section_name),
         i.quantity::bigint, i.line_total::bigint
    from public.offline_orders f
    join public.offline_order_items i on i.offline_order_id = f.id
    left join public.products p on p.id = i.product_id
    left join public.menu_sections s on s.id = p.section_id
   where f.deleted_at is null and f.entry_mode = 'items' and f.order_date >= r_from and f.order_date < r_to;
$$;
revoke execute on function public.cf_menu_lines(timestamptz, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------- 1. summary cards
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
      'mock_order_value',     coalesce(sum(total) filter (where classification = 'mock'), 0),
      'mock_system_value',    coalesce(sum(total) filter (where kind = 'system'  and classification = 'mock'), 0),
      'mock_offline_value',   coalesce(sum(total) filter (where kind = 'offline' and classification = 'mock'), 0),
      'mock_orders',           count(*)       filter (where classification = 'mock'),
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
                          where o.status = 'completed' and o.classification_review
                            and o.completed_at >= r.r_from and o.completed_at < r.r_to),
    'estimated_completion_dates', (select count(*) from public.orders o
                          where o.status = 'completed' and o.completed_at_estimated
                            and o.completed_at >= r.r_from and o.completed_at < r.r_to),
    'payments_mode', (select payments_mode from public.shop_settings where id = 1),
    'refunds_tracked', false);
end $$;

-- ---------------------------------------------------------------- 2. unified transaction history
-- p: from, to (dates), type income|expense, classification real|mock, source system_real|system_mock|offline|expense,
--    payment cash|bank_transfer|qris|card|other, category_id, review (true = only orders that need review),
--    q (search), page (1..), page_size (<=100)
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
     where (v_type is null or ttype = v_type)
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

-- ---------------------------------------------------------------- 3. menu sales
-- p_scope 'real' (default) or 'mock'; p_group 'product' (base menu) or 'variant'
create or replace function public.cashflow_menu_sales(p_from date, p_to date, p_scope text default 'real', p_group text default 'product')
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r record; v_total_rev bigint; v_total_qty bigint; v_rows jsonb; v_cats jsonb; v_amount jsonb;
begin
  perform public.cf_require_admin();
  if p_scope not in ('real','mock') then raise exception 'INVALID_FILTER:scope'; end if;
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

-- ---------------------------------------------------------------- 4. classify an online order
create or replace function public.cashflow_set_order_classification(p_order_id uuid, p_classification text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_old public.orders; v_new public.orders;
begin
  perform public.cf_require_admin();
  if p_classification not in ('real','mock') then raise exception 'INVALID_CLASSIFICATION'; end if;
  select * into v_old from public.orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  -- only the classification fields change; status, totals and payment stay untouched
  update public.orders
     set classification = p_classification, classification_source = 'admin', classification_review = false,
         classification_note = coalesce(nullif(trim(p_note), ''), classification_note)
   where id = p_order_id
  returning * into v_new;
  perform public.cf_log('order', p_order_id::text,
    case when v_old.classification = p_classification then 'review' else 'classify' end,
    jsonb_build_object('classification', v_old.classification, 'source', v_old.classification_source, 'review', v_old.classification_review),
    jsonb_build_object('classification', v_new.classification, 'source', v_new.classification_source, 'review', v_new.classification_review));
  return jsonb_build_object('id', v_new.id, 'classification', v_new.classification, 'review', v_new.classification_review);
end $$;

create or replace function public.cashflow_set_payments_mode(p_mode text)
returns text language plpgsql security definer set search_path = public as $$
declare v_old text;
begin
  perform public.cf_require_admin();
  if p_mode not in ('sandbox','production') then raise exception 'INVALID_MODE'; end if;
  select payments_mode into v_old from public.shop_settings where id = 1 for update;
  update public.shop_settings set payments_mode = p_mode where id = 1;   -- logged by trg_shop_settings_cf_mode
  return p_mode;
end $$;

-- ---------------------------------------------------------------- 5. offline orders
-- p: id (null = new), version (when editing), client_token (uuid, required for new),
--    order_date (timestamptz), order_ref, customer_name, source, payment_method, classification,
--    entry_mode 'items'|'amount', items [{variant_id | product_id | product_name, quantity, unit_price?, discount}],
--    amount (amount mode), order_discount, extra_charge, notes, expected_total (optional cross-check)
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
begin
  perform public.cf_require_admin();

  begin v_token := (p->>'client_token')::uuid; exception when others then raise exception 'INVALID_CLIENT_TOKEN'; end;
  begin v_date := (p->>'order_date')::timestamptz; exception when others then raise exception 'INVALID_DATE'; end;
  if v_date is null then raise exception 'DATE_REQUIRED'; end if;
  if v_date > now() + interval '1 day' then raise exception 'DATE_IN_FUTURE'; end if;
  if v_date < '2020-01-01' then raise exception 'INVALID_DATE'; end if;
  if v_source not in ('walk_in','whatsapp','phone','social_media','other') then raise exception 'INVALID_SOURCE'; end if;
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
          classification, entry_mode, subtotal, item_discount, order_discount, extra_charge, total, notes, created_by, updated_by)
      values (v_token, v_ref, v_date, left(public.cf_text(p, 'customer_name'), 120), v_source, v_pay,
          v_class, v_mode, v_sub, v_item_disc, v_order_disc, v_extra, v_total, left(public.cf_text(p, 'notes'), 1000), auth.uid(), auth.uid())
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
             total = v_total, notes = left(public.cf_text(p, 'notes'), 1000), version = version + 1, updated_by = auth.uid()
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

create or replace function public.cashflow_delete_offline_order(p_id bigint, p_version integer)
returns boolean language plpgsql security definer set search_path = public as $$
declare v public.offline_orders;
begin
  perform public.cf_require_admin();
  select * into v from public.offline_orders where id = p_id for update;
  if not found or v.deleted_at is not null then raise exception 'RECORD_NOT_FOUND'; end if;
  if p_version is distinct from v.version then raise exception 'STALE_RECORD'; end if;
  update public.offline_orders set deleted_at = now(), deleted_by = auth.uid(), version = version + 1 where id = p_id;
  perform public.cf_log('offline_order', p_id::text, 'delete', to_jsonb(v), null);
  return true;
end $$;

-- ---------------------------------------------------------------- 6. expenses
-- p: id, version, client_token, expense_date, description, category_id, amount, payment_method, vendor, receipt_path, notes
create or replace function public.cashflow_save_expense(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id bigint := public.cf_int(p, 'id');
  v_token uuid; v_date timestamptz;
  v_amount integer := public.cf_int(p, 'amount');
  v_desc text := public.cf_text(p, 'description');
  v_cat public.expense_categories;
  v_pay text := public.cf_text(p, 'payment_method');
  v_receipt text := public.cf_text(p, 'receipt_path');
  v_old public.expenses; v_row public.expenses;
begin
  perform public.cf_require_admin();
  begin v_token := (p->>'client_token')::uuid; exception when others then raise exception 'INVALID_CLIENT_TOKEN'; end;
  begin v_date := (p->>'expense_date')::timestamptz; exception when others then raise exception 'INVALID_DATE'; end;
  if v_date is null then raise exception 'DATE_REQUIRED'; end if;
  if v_date > now() + interval '1 day' then raise exception 'DATE_IN_FUTURE'; end if;
  if v_date < '2020-01-01' then raise exception 'INVALID_DATE'; end if;
  if v_desc is null then raise exception 'DESCRIPTION_REQUIRED'; end if;
  if length(v_desc) > 200 then raise exception 'DESCRIPTION_TOO_LONG'; end if;
  if v_amount is null or v_amount <= 0 then raise exception 'AMOUNT_MUST_BE_POSITIVE'; end if;
  if v_amount > 1000000000 then raise exception 'AMOUNT_TOO_LARGE'; end if;
  if v_pay is null or v_pay not in ('cash','bank_transfer','qris','other') then raise exception 'INVALID_PAYMENT_METHOD'; end if;
  if v_receipt is not null and v_receipt !~ '^[A-Za-z0-9/_.-]{1,200}$' then raise exception 'INVALID_RECEIPT_PATH'; end if;
  select * into v_cat from public.expense_categories where id = public.cf_int(p, 'category_id');
  if v_cat.id is null then raise exception 'CATEGORY_REQUIRED'; end if;

  if v_id is null then
    if v_token is null then raise exception 'CLIENT_TOKEN_REQUIRED'; end if;
    if not v_cat.is_active then raise exception 'CATEGORY_INACTIVE'; end if;
    select * into v_row from public.expenses where client_token = v_token;
    if found then return jsonb_build_object('id', v_row.id, 'version', v_row.version, 'duplicate', true); end if;
    insert into public.expenses (client_token, expense_date, description, category_id, category_name, amount,
        payment_method, vendor, receipt_path, notes, created_by, updated_by)
    values (v_token, v_date, v_desc, v_cat.id, v_cat.name, v_amount, v_pay, left(public.cf_text(p, 'vendor'), 120),
        v_receipt, left(public.cf_text(p, 'notes'), 1000), auth.uid(), auth.uid())
    on conflict (client_token) do nothing
    returning * into v_row;
    if v_row.id is null then
      select * into v_row from public.expenses where client_token = v_token;
      return jsonb_build_object('id', v_row.id, 'version', v_row.version, 'duplicate', true);
    end if;
  else
    select * into v_old from public.expenses where id = v_id for update;
    if not found or v_old.deleted_at is not null then raise exception 'RECORD_NOT_FOUND'; end if;
    if public.cf_int(p, 'version') is distinct from v_old.version then raise exception 'STALE_RECORD'; end if;
    -- an inactive category may stay on an old expense, but can't be newly chosen
    if not v_cat.is_active and v_cat.id is distinct from v_old.category_id then raise exception 'CATEGORY_INACTIVE'; end if;
    update public.expenses
       set expense_date = v_date, description = v_desc, category_id = v_cat.id,
           category_name = case when v_cat.id = v_old.category_id then v_old.category_name else v_cat.name end,
           amount = v_amount, payment_method = v_pay, vendor = left(public.cf_text(p, 'vendor'), 120),
           receipt_path = v_receipt, notes = left(public.cf_text(p, 'notes'), 1000),
           version = version + 1, updated_by = auth.uid()
     where id = v_id returning * into v_row;
  end if;
  perform public.cf_log('expense', v_row.id::text, case when v_id is null then 'create' else 'update' end,
    case when v_id is null then null else to_jsonb(v_old) end, to_jsonb(v_row));
  return jsonb_build_object('id', v_row.id, 'version', v_row.version, 'duplicate', false);
end $$;

create or replace function public.cashflow_delete_expense(p_id bigint, p_version integer)
returns boolean language plpgsql security definer set search_path = public as $$
declare v public.expenses;
begin
  perform public.cf_require_admin();
  select * into v from public.expenses where id = p_id for update;
  if not found or v.deleted_at is not null then raise exception 'RECORD_NOT_FOUND'; end if;
  if p_version is distinct from v.version then raise exception 'STALE_RECORD'; end if;
  update public.expenses set deleted_at = now(), deleted_by = auth.uid(), version = version + 1 where id = p_id;
  perform public.cf_log('expense', p_id::text, 'delete', to_jsonb(v), null);
  return true;
end $$;

-- categories: list (with usage), add / rename / hide. Never deleted, so old expenses keep their category.
create or replace function public.cashflow_categories()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.cf_require_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'is_default', c.is_default,
            'is_active', c.is_active, 'used', (select count(*) from public.expenses e where e.category_id = c.id and e.deleted_at is null))
            order by c.sort_order, c.id) from public.expense_categories c), '[]');
end $$;

create or replace function public.cashflow_save_category(p_id bigint, p_name text, p_active boolean default true)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_old public.expense_categories; v_new public.expense_categories;
begin
  perform public.cf_require_admin();
  p_name := nullif(trim(p_name), '');
  if p_name is null then raise exception 'NAME_REQUIRED'; end if;
  if length(p_name) > 60 then raise exception 'NAME_TOO_LONG'; end if;
  begin
    if p_id is null then
      insert into public.expense_categories (name, is_active, sort_order)
      values (p_name, coalesce(p_active, true), (select coalesce(max(sort_order), 0) + 1 from public.expense_categories))
      returning * into v_new;
    else
      select * into v_old from public.expense_categories where id = p_id for update;
      if not found then raise exception 'RECORD_NOT_FOUND'; end if;
      update public.expense_categories set name = p_name, is_active = coalesce(p_active, is_active) where id = p_id returning * into v_new;
    end if;
  exception when unique_violation then raise exception 'DUPLICATE_NAME';
  end;
  perform public.cf_log('expense_category', v_new.id::text, case when p_id is null then 'create' else 'update' end,
    case when p_id is null then null else to_jsonb(v_old) end, to_jsonb(v_new));
  return v_new.id;
end $$;

-- menu for the offline order form: every product and variant, with current price and submenu
create or replace function public.cashflow_menu_catalog()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.cf_require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'is_active', p.is_active,
             'section_id', p.section_id, 'section_name', s.name,
             'variants', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name, 'price', v.price, 'is_active', v.is_active)
                                     order by v.sort_order, v.id) from public.product_variants v where v.product_id = p.id), '[]'))
           order by s.sort_order nulls last, p.sort_order, p.id)
      from public.products p left join public.menu_sections s on s.id = p.section_id), '[]');
end $$;

create or replace function public.cashflow_history(p_entity text, p_id text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.cf_require_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('at', a.at, 'action', a.action, 'by', coalesce(pr.full_name, 'Admin'),
                     'before', a.before, 'after', a.after) order by a.at desc, a.id desc)
                     from public.cashflow_audit a left join public.profiles pr on pr.id = a.actor
                    where a.entity = p_entity and a.entity_id = p_id), '[]');
end $$;

-- ---------------------------------------------------------------- permissions
revoke execute on function public.cf_pay_group(text) from public, anon, authenticated;
revoke execute on function public.cf_int(jsonb, text, integer) from public, anon, authenticated;
revoke execute on function public.cf_text(jsonb, text) from public, anon, authenticated;
revoke execute on function public.trg_cf_order_insert() from public, anon, authenticated;
revoke execute on function public.trg_cf_order_update() from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'public.cashflow_summary(date, date)',
    'public.cashflow_transactions(jsonb)',
    'public.cashflow_menu_sales(date, date, text, text)',
    'public.cashflow_set_order_classification(uuid, text, text)',
    'public.cashflow_set_payments_mode(text)',
    'public.cashflow_save_offline_order(jsonb)',
    'public.cashflow_delete_offline_order(bigint, integer)',
    'public.cashflow_save_expense(jsonb)',
    'public.cashflow_delete_expense(bigint, integer)',
    'public.cashflow_categories()',
    'public.cashflow_save_category(bigint, text, boolean)',
    'public.cashflow_menu_catalog()',
    'public.cashflow_history(text, text)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);   -- each one checks is_admin() itself
  end loop;
end $$;

commit;
