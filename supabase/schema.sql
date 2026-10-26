-- =====================================================================
-- CamilaNika shop — Supabase database schema (v2)
-- Run once in Supabase: SQL Editor → New query → paste → Run.
-- Then run seed.sql to load the current menu.
--
-- Model
--   products          one menu item (e.g. "Flavored Americano")
--   product_variants  each sellable version with its own price & stock
--                     (e.g. "Peach · M", "Keju Lumer · Isi 6 · Frozen")
--   inventory         stock per variant (stock on hand + reserved by unpaid orders)
--   promotions        percent / fixed discount / free gift, auto or by code
--   orders            logged-in or guest orders, paid via Midtrans
--
-- Money is whole Rupiah (integer).
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 0. Helpers
-- ---------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 1. Profiles + admin role
-- ---------------------------------------------------------------------
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  phone       text,
  address     text,
  role        text not null default 'customer' check (role in ('customer','admin')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create trigger trg_profiles_updated before update on public.profiles
  for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, phone)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
          new.raw_user_meta_data->>'phone');
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- ---------------------------------------------------------------------
-- 2. Products, variants, inventory
-- ---------------------------------------------------------------------
create table public.products (
  id           bigint generated always as identity primary key,
  name         text not null,
  slug         text not null unique,
  series       text not null default 'coffee',  -- coffee | choco | matcha | cireng | ...
  subtitle     text,                            -- short description under the name
  note         text,                            -- small tag, e.g. 'Mengandung kopi'
  image_url    text,
  attr_names   text[] not null default '{}',    -- variant attributes in display order, e.g. {Rasa,Ukuran}
  choices      jsonb  not null default '[]',    -- free options, e.g. [{"label":"Tingkat gula","options":["Less Sugar","Normal Sugar"],"default":1}]
  addon_label  text,                            -- optional paid add-on, e.g. 'Extra shot'
  is_active    boolean not null default true,
  sort_order   integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create trigger trg_products_updated before update on public.products
  for each row execute function public.set_updated_at();

create table public.product_variants (
  id           bigint generated always as identity primary key,
  product_id   bigint not null references public.products(id) on delete cascade,
  name         text not null,                   -- e.g. 'Peach · M 500 ml'
  attrs        jsonb not null default '{}',     -- e.g. {"Rasa":"Peach","Ukuran":"M"}
  sku          text unique,
  price        integer not null check (price >= 0),
  addon_price  integer check (addon_price >= 0), -- price of the add-on for this variant (null = not offered)
  is_active    boolean not null default true,
  sort_order   integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index product_variants_product_idx on public.product_variants(product_id);
create trigger trg_variants_updated before update on public.product_variants
  for each row execute function public.set_updated_at();

-- stock = on hand, reserved = held by unpaid orders, available = stock - reserved
create table public.inventory (
  variant_id           bigint primary key references public.product_variants(id) on delete cascade,
  stock                integer not null default 0 check (stock >= 0),
  reserved             integer not null default 0 check (reserved >= 0),
  low_stock_threshold  integer not null default 5,
  updated_at           timestamptz not null default now(),
  check (reserved <= stock)
);
create trigger trg_inventory_updated before update on public.inventory
  for each row execute function public.set_updated_at();

create or replace function public.handle_new_variant()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.inventory (variant_id) values (new.id) on conflict do nothing;
  return new;
end $$;
create trigger on_variant_created after insert on public.product_variants
  for each row execute function public.handle_new_variant();

create table public.stock_movements (
  id          bigint generated always as identity primary key,
  variant_id  bigint not null references public.product_variants(id) on delete cascade,
  change      integer not null,
  reason      text not null check (reason in ('restock','adjustment','sale','waste')),
  note        text,
  order_id    uuid,
  created_by  uuid references auth.users(id),
  created_at  timestamptz not null default now()
);
create index stock_movements_variant_idx on public.stock_movements(variant_id, created_at desc);

-- ---------------------------------------------------------------------
-- 3. Promotions
-- ---------------------------------------------------------------------
-- code IS NULL  -> automatic (best discount wins; all qualifying gifts are given)
-- code NOT NULL -> customer types the code
-- discount_type: percent (value = %), fixed (value = Rupiah), free_item (gift_text, value ignored)
create table public.promotions (
  id              bigint generated always as identity primary key,
  name            text not null,
  description     text,                      -- shown to customers (banner / cart)
  code            text unique,
  discount_type   text not null check (discount_type in ('percent','fixed','free_item')),
  value           integer not null default 0 check (value >= 0),
  gift_text       text,                      -- for free_item, e.g. 'Free latte 150 ml'
  min_spend       integer not null default 0 check (min_spend >= 0),
  max_discount    integer check (max_discount > 0),
  applies_to_all  boolean not null default true,
  starts_at       timestamptz,
  ends_at         timestamptz,
  usage_limit     integer check (usage_limit > 0),
  used_count      integer not null default 0,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (discount_type <> 'percent' or value between 1 and 100),
  check (discount_type <> 'fixed' or value > 0),
  check (discount_type <> 'free_item' or gift_text is not null)
);
create trigger trg_promotions_updated before update on public.promotions
  for each row execute function public.set_updated_at();

create or replace function public.promotions_upper_code()
returns trigger language plpgsql as $$
begin
  new.code := nullif(upper(trim(new.code)), '');
  return new;
end $$;
create trigger trg_promotions_code before insert or update on public.promotions
  for each row execute function public.promotions_upper_code();

-- When applies_to_all = false: which products count towards the promo
create table public.promotion_products (
  promotion_id  bigint references public.promotions(id) on delete cascade,
  product_id    bigint references public.products(id) on delete cascade,
  primary key (promotion_id, product_id)
);

-- ---------------------------------------------------------------------
-- 4. Orders
-- ---------------------------------------------------------------------
create table public.orders (
  id               uuid primary key default gen_random_uuid(),
  order_number     text not null unique,         -- Midtrans order_id
  access_token     uuid not null default gen_random_uuid(),  -- lets a guest check their order status
  user_id          uuid references auth.users(id),           -- null = guest
  status           text not null default 'pending'
                   check (status in ('pending','paid','processing','completed','cancelled','expired','failed')),
  subtotal         integer not null,
  discount         integer not null default 0,
  total            integer not null,
  promotion_id     bigint references public.promotions(id),
  promo_code       text,
  gifts            jsonb not null default '[]',
  customer_name    text not null,
  phone            text not null,
  email            text,
  address          text,
  notes            text,
  payment_provider text default 'midtrans',
  payment_ref      text,
  payment_method   text,
  paid_at          timestamptz,
  expires_at       timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index orders_user_idx on public.orders(user_id, created_at desc);
create index orders_status_idx on public.orders(status, expires_at);
create trigger trg_orders_updated before update on public.orders
  for each row execute function public.set_updated_at();

create table public.order_items (
  id            bigint generated always as identity primary key,
  order_id      uuid not null references public.orders(id) on delete cascade,
  variant_id    bigint references public.product_variants(id) on delete set null,
  product_id    bigint references public.products(id) on delete set null,
  product_name  text not null,       -- snapshots so history survives menu edits
  variant_name  text not null,
  choices       jsonb not null default '{}',
  addon         text,                -- e.g. 'Extra shot' (null if none)
  unit_price    integer not null,    -- variant price + add-on
  quantity      integer not null check (quantity > 0),
  line_total    integer not null
);
create index order_items_order_idx on public.order_items(order_id);

-- ---------------------------------------------------------------------
-- 5. Public menu (one call for the shop page)
-- ---------------------------------------------------------------------
create or replace function public.get_menu()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'name', p.name, 'slug', p.slug, 'series', p.series,
        'subtitle', p.subtitle, 'note', p.note, 'image_url', p.image_url,
        'attr_names', to_jsonb(p.attr_names), 'choices', p.choices, 'addon_label', p.addon_label,
        'variants', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', v.id, 'name', v.name, 'attrs', v.attrs, 'price', v.price,
            'addon_price', v.addon_price,
            'available', greatest(coalesce(i.stock,0) - coalesce(i.reserved,0), 0))
            order by v.sort_order, v.id)
          from public.product_variants v
          left join public.inventory i on i.variant_id = v.id
          where v.product_id = p.id and v.is_active), '[]'::jsonb))
        order by p.sort_order, p.id)
      from public.products p where p.is_active), '[]'::jsonb),
    'promotions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pr.id, 'name', pr.name, 'description', pr.description,
        'discount_type', pr.discount_type, 'value', pr.value, 'gift_text', pr.gift_text,
        'min_spend', pr.min_spend, 'max_discount', pr.max_discount, 'ends_at', pr.ends_at)
        order by pr.min_spend)
      from public.promotions pr
      where pr.code is null and pr.is_active
        and (pr.starts_at is null or pr.starts_at <= now())
        and (pr.ends_at is null or pr.ends_at > now())
        and (pr.usage_limit is null or pr.used_count < pr.usage_limit)), '[]'::jsonb));
$$;

-- ---------------------------------------------------------------------
-- 6. Pricing a cart (preview in browser AND final price in create_order)
--    p_items = [{"variant_id":12,"quantity":2,"addon":true,"choices":{"Tingkat gula":"Less Sugar"}}, ...]
-- ---------------------------------------------------------------------
create or replace function public.quote_cart(p_items jsonb, p_promo_code text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_lines     jsonb := '[]'::jsonb;
  v_subtotal  integer := 0;
  e           jsonb;
  v_var       record;
  v_qty       integer;
  v_addon     boolean;
  v_choices   jsonb;
  v_grp       jsonb;
  v_val       text;
  v_unit      integer;
  v_short     record;
  v_promo     public.promotions;
  v_best      public.promotions;
  v_best_disc integer := 0;
  v_disc      integer;
  v_eligible  integer;
  v_gifts     jsonb := '[]'::jsonb;
  v_code      text := nullif(upper(trim(p_promo_code)), '');
  v_code_ok   boolean := false;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'CART_EMPTY';
  end if;
  if jsonb_array_length(p_items) > 50 then raise exception 'CART_TOO_LARGE'; end if;

  for e in select * from jsonb_array_elements(p_items) loop
    v_qty := (e->>'quantity')::int;
    if v_qty is null or v_qty <= 0 or v_qty > 100 then raise exception 'INVALID_QUANTITY'; end if;

    select v.id, v.name as vname, v.price, v.addon_price, p.id as pid, p.name as pname,
           p.choices, p.addon_label
      into v_var
      from public.product_variants v join public.products p on p.id = v.product_id
     where v.id = (e->>'variant_id')::bigint and v.is_active and p.is_active;
    if not found then raise exception 'PRODUCT_UNAVAILABLE:%', e->>'variant_id'; end if;

    v_addon := coalesce((e->>'addon')::boolean, false);
    if v_addon and (v_var.addon_label is null or v_var.addon_price is null) then
      raise exception 'ADDON_UNAVAILABLE:%', v_var.id;
    end if;

    -- validate free choices against the product's allowed options
    v_choices := '{}'::jsonb;
    for v_grp in select * from jsonb_array_elements(v_var.choices) loop
      v_val := e->'choices'->>(v_grp->>'label');
      if v_val is null then
        v_val := v_grp->'options'->>coalesce((v_grp->>'default')::int, 0);
      elsif not (v_grp->'options' ? v_val) then
        raise exception 'INVALID_CHOICE:%', v_grp->>'label';
      end if;
      v_choices := v_choices || jsonb_build_object(v_grp->>'label', v_val);
    end loop;

    v_unit := v_var.price + case when v_addon then v_var.addon_price else 0 end;
    v_lines := v_lines || jsonb_build_object(
      'variant_id', v_var.id, 'product_id', v_var.pid,
      'product_name', v_var.pname, 'variant_name', v_var.vname,
      'choices', v_choices, 'addon', case when v_addon then v_var.addon_label end,
      'unit_price', v_unit, 'quantity', v_qty, 'line_total', v_unit * v_qty);
    v_subtotal := v_subtotal + v_unit * v_qty;
  end loop;

  -- stock check per variant (same variant may appear on several lines)
  for v_short in
    select (l->>'variant_id')::bigint as vid, sum((l->>'quantity')::int) as qty,
           max(greatest(coalesce(i.stock,0) - coalesce(i.reserved,0), 0)) as available
      from jsonb_array_elements(v_lines) l
      left join public.inventory i on i.variant_id = (l->>'variant_id')::bigint
     group by 1
  loop
    if v_short.qty > v_short.available then
      raise exception 'OUT_OF_STOCK:%:%', v_short.vid, v_short.available;
    end if;
  end loop;

  -- promotions
  for v_promo in
    select * from public.promotions pr
     where pr.is_active
       and (pr.starts_at is null or pr.starts_at <= now())
       and (pr.ends_at   is null or pr.ends_at   >  now())
       and (pr.usage_limit is null or pr.used_count < pr.usage_limit)
       and (pr.code is null or pr.code = v_code)
  loop
    select coalesce(sum((l->>'line_total')::int), 0) into v_eligible
      from jsonb_array_elements(v_lines) l
     where v_promo.applies_to_all
        or exists (select 1 from public.promotion_products pp
                    where pp.promotion_id = v_promo.id and pp.product_id = (l->>'product_id')::bigint);
    if v_eligible = 0 or v_eligible < v_promo.min_spend then continue; end if;
    if v_promo.code is not null then v_code_ok := true; end if;

    if v_promo.discount_type = 'free_item' then
      v_gifts := v_gifts || jsonb_build_object('promotion_id', v_promo.id, 'name', v_promo.name, 'gift', v_promo.gift_text);
      continue;
    end if;

    if v_promo.discount_type = 'percent' then
      v_disc := floor(v_eligible * v_promo.value / 100.0);
      if v_promo.max_discount is not null then v_disc := least(v_disc, v_promo.max_discount); end if;
    else
      v_disc := least(v_promo.value, v_eligible);
    end if;
    -- a typed code always wins over automatic discounts
    if (v_promo.code is not null and (v_best.id is null or v_best.code is null or v_disc > v_best_disc))
       or (v_promo.code is null and (v_best.id is null or v_best.code is null) and v_disc > v_best_disc) then
      v_best_disc := v_disc;
      v_best := v_promo;
    end if;
  end loop;

  if v_code is not null and not v_code_ok then
    raise exception 'PROMO_NOT_APPLICABLE';
  end if;

  return jsonb_build_object(
    'items', v_lines, 'subtotal', v_subtotal, 'discount', v_best_disc,
    'total', v_subtotal - v_best_disc,
    'promotion_id', v_best.id, 'promo_name', v_best.name, 'promo_code', v_code,
    'gifts', v_gifts);
end $$;

-- ---------------------------------------------------------------------
-- 7. Create order + reserve stock (Edge Function only)
-- ---------------------------------------------------------------------
create or replace function public.create_order(
  p_user_id uuid, p_items jsonb, p_promo_code text,
  p_customer_name text, p_phone text, p_email text default null,
  p_address text default null, p_notes text default null,
  p_expires_minutes integer default 30)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_quote  jsonb;
  v_order  public.orders;
  v_line   jsonb;
  v_number text;
begin
  if coalesce(trim(p_customer_name), '') = '' then raise exception 'NAME_REQUIRED'; end if;
  if coalesce(trim(p_phone), '') = '' then raise exception 'PHONE_REQUIRED'; end if;

  -- lock stock rows so two buyers can't take the last item at the same time
  perform 1 from public.inventory
   where variant_id in (select (x->>'variant_id')::bigint from jsonb_array_elements(p_items) x)
   order by variant_id for update;

  v_quote := public.quote_cart(p_items, p_promo_code);

  v_number := 'CN-' || to_char(now() at time zone 'Asia/Jakarta', 'YYMMDD') || '-'
              || upper(substr(md5(gen_random_uuid()::text), 1, 6));

  insert into public.orders (order_number, user_id, subtotal, discount, total, promotion_id, promo_code,
                             gifts, customer_name, phone, email, address, notes, expires_at)
  values (v_number, p_user_id,
          (v_quote->>'subtotal')::int, (v_quote->>'discount')::int, (v_quote->>'total')::int,
          (v_quote->>'promotion_id')::bigint, v_quote->>'promo_code', v_quote->'gifts',
          trim(p_customer_name), trim(p_phone), nullif(trim(p_email), ''),
          p_address, p_notes, now() + make_interval(mins => p_expires_minutes))
  returning * into v_order;

  for v_line in select * from jsonb_array_elements(v_quote->'items') loop
    insert into public.order_items (order_id, variant_id, product_id, product_name, variant_name,
                                    choices, addon, unit_price, quantity, line_total)
    values (v_order.id, (v_line->>'variant_id')::bigint, (v_line->>'product_id')::bigint,
            v_line->>'product_name', v_line->>'variant_name', v_line->'choices', v_line->>'addon',
            (v_line->>'unit_price')::int, (v_line->>'quantity')::int, (v_line->>'line_total')::int);
    update public.inventory set reserved = reserved + (v_line->>'quantity')::int
     where variant_id = (v_line->>'variant_id')::bigint;
  end loop;

  return v_quote || jsonb_build_object(
    'order_id', v_order.id, 'order_number', v_order.order_number,
    'access_token', v_order.access_token, 'expires_at', v_order.expires_at);
end $$;

-- ---------------------------------------------------------------------
-- 8. Payment settled -> deduct stock (idempotent)
-- ---------------------------------------------------------------------
create or replace function public.mark_order_paid(
  p_order_number text, p_payment_ref text default null, p_payment_method text default null)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_order public.orders;
  v_pid   bigint;
begin
  select * into v_order from public.orders where order_number = p_order_number for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;

  if v_order.status = 'pending' then
    -- normal case: turn the reservation into a sale
    update public.inventory i
       set stock = i.stock - x.qty, reserved = greatest(i.reserved - x.qty, 0)
      from (select variant_id, sum(quantity) qty from public.order_items
             where order_id = v_order.id and variant_id is not null group by 1) x
     where i.variant_id = x.variant_id;
  elsif v_order.status in ('expired','failed','cancelled') and v_order.paid_at is null then
    -- late payment after the reservation was released: take stock anyway (may go to 0)
    update public.inventory i
       set stock = greatest(i.stock - x.qty, i.reserved)
      from (select variant_id, sum(quantity) qty from public.order_items
             where order_id = v_order.id and variant_id is not null group by 1) x
     where i.variant_id = x.variant_id;
  else
    return v_order.status;  -- already paid / processing / completed
  end if;

  insert into public.stock_movements (variant_id, change, reason, order_id)
  select variant_id, -sum(quantity), 'sale', v_order.id
    from public.order_items where order_id = v_order.id and variant_id is not null group by variant_id;

  update public.promotions set used_count = used_count + 1
   where id in (select v_order.promotion_id
                union select (g->>'promotion_id')::bigint from jsonb_array_elements(v_order.gifts) g);

  update public.orders
     set status = 'paid', paid_at = now(), payment_ref = p_payment_ref, payment_method = p_payment_method
   where id = v_order.id;
  return 'paid';
end $$;

-- ---------------------------------------------------------------------
-- 9. Payment failed / expired / cancelled -> release reservation
-- ---------------------------------------------------------------------
create or replace function public.release_order(p_order_number text, p_status text default 'expired')
returns text language plpgsql security definer set search_path = public as $$
declare
  v_order public.orders;
begin
  if p_status not in ('expired','failed','cancelled') then raise exception 'INVALID_STATUS'; end if;
  select * into v_order from public.orders where order_number = p_order_number for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_order.status <> 'pending' then return v_order.status; end if;

  update public.inventory i
     set reserved = greatest(i.reserved - x.qty, 0)
    from (select variant_id, sum(quantity) qty from public.order_items
           where order_id = v_order.id and variant_id is not null group by 1) x
   where i.variant_id = x.variant_id;

  update public.orders set status = p_status where id = v_order.id;
  return p_status;
end $$;

-- Safety net for abandoned checkouts. Optional schedule (Database → Extensions → enable pg_cron):
--   select cron.schedule('release-expired-orders', '*/5 * * * *', 'select public.release_expired_orders()');
create or replace function public.release_expired_orders()
returns integer language plpgsql security definer set search_path = public as $$
declare v_num text; v_count integer := 0;
begin
  for v_num in select order_number from public.orders
                where status = 'pending' and expires_at < now() - interval '15 minutes'
  loop
    perform public.release_order(v_num, 'expired');
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

-- ---------------------------------------------------------------------
-- 10. Guest order status (needs the secret access_token)
-- ---------------------------------------------------------------------
create or replace function public.get_order_status(p_order_number text, p_access_token uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'order_number', o.order_number, 'status', o.status, 'total', o.total,
    'subtotal', o.subtotal, 'discount', o.discount, 'gifts', o.gifts,
    'created_at', o.created_at, 'paid_at', o.paid_at,
    'items', (select jsonb_agg(jsonb_build_object('product_name', product_name, 'variant_name', variant_name,
                     'choices', choices, 'addon', addon, 'quantity', quantity, 'line_total', line_total) order by id)
                from public.order_items where order_id = o.id))
  from public.orders o
  where o.order_number = p_order_number and o.access_token = p_access_token;
$$;

-- ---------------------------------------------------------------------
-- 11. Admin actions
-- ---------------------------------------------------------------------
create or replace function public.admin_adjust_stock(
  p_variant_id bigint, p_change integer, p_reason text default 'restock', p_note text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare v_stock integer;
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  if p_reason not in ('restock','adjustment','waste') then raise exception 'INVALID_REASON'; end if;
  if p_change = 0 then raise exception 'NO_CHANGE'; end if;

  update public.inventory set stock = stock + p_change
   where variant_id = p_variant_id
  returning stock into v_stock;
  if not found then raise exception 'VARIANT_NOT_FOUND'; end if;

  insert into public.stock_movements (variant_id, change, reason, note, created_by)
  values (p_variant_id, p_change, p_reason, p_note, auth.uid());
  return v_stock;
end $$;

-- Move an order along: paid -> processing -> completed, or cancel.
create or replace function public.admin_set_order_status(p_order_id uuid, p_status text)
returns text language plpgsql security definer set search_path = public as $$
declare v_order public.orders;
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;

  if p_status = 'cancelled' and v_order.status = 'pending' then
    return public.release_order(v_order.order_number, 'cancelled');
  elsif p_status = 'cancelled' and v_order.status in ('paid','processing') then
    -- paid order cancelled: refund is done manually in Midtrans; stock is NOT returned automatically
    update public.orders set status = 'cancelled' where id = p_order_id;
  elsif p_status = 'processing' and v_order.status = 'paid'
     or p_status = 'completed'  and v_order.status in ('paid','processing') then
    update public.orders set status = p_status where id = p_order_id;
  else
    raise exception 'INVALID_TRANSITION:%->%', v_order.status, p_status;
  end if;
  return p_status;
end $$;

-- ---------------------------------------------------------------------
-- 12. Row-level security
-- ---------------------------------------------------------------------
alter table public.profiles           enable row level security;
alter table public.products           enable row level security;
alter table public.product_variants   enable row level security;
alter table public.inventory          enable row level security;
alter table public.stock_movements    enable row level security;
alter table public.promotions         enable row level security;
alter table public.promotion_products enable row level security;
alter table public.orders             enable row level security;
alter table public.order_items        enable row level security;

create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_admin());
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.profiles from anon, authenticated;
grant update (full_name, phone, address) on public.profiles to authenticated;

-- Catalogue: everyone reads (shop uses get_menu), admins manage
create policy products_select on public.products for select to anon, authenticated
  using (is_active or public.is_admin());
create policy products_admin on public.products for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy variants_select on public.product_variants for select to anon, authenticated
  using (is_active or public.is_admin());
create policy variants_admin on public.product_variants for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Inventory: admins only (shop sees availability via get_menu). Stock changes via admin_adjust_stock.
create policy inventory_admin_select on public.inventory for select to authenticated
  using (public.is_admin());
create policy inventory_admin_update on public.inventory for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
revoke update on public.inventory from anon, authenticated;
grant update (low_stock_threshold) on public.inventory to authenticated;

create policy stock_movements_admin on public.stock_movements for select to authenticated
  using (public.is_admin());

-- Promotions: admins only (shop sees automatic promos via get_menu; codes stay secret)
create policy promotions_admin on public.promotions for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy promotion_products_admin on public.promotion_products for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Orders: customers read their own; admins read all. All writes go through functions.
create policy orders_select on public.orders for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
create policy order_items_select on public.order_items for select to authenticated
  using (exists (select 1 from public.orders o
                 where o.id = order_id and (o.user_id = auth.uid() or public.is_admin())));
revoke insert, update, delete on public.orders, public.order_items from anon, authenticated;
revoke insert, update, delete on public.stock_movements from anon, authenticated;

-- ---------------------------------------------------------------------
-- 13. Function permissions
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function public.is_admin()                               to anon, authenticated;
grant execute on function public.get_menu()                               to anon, authenticated;
grant execute on function public.quote_cart(jsonb, text)                  to anon, authenticated;
grant execute on function public.get_order_status(text, uuid)             to anon, authenticated;
grant execute on function public.admin_adjust_stock(bigint, integer, text, text) to authenticated;
grant execute on function public.admin_set_order_status(uuid, text)       to authenticated;

grant execute on function public.create_order(uuid, jsonb, text, text, text, text, text, text, integer) to service_role;
grant execute on function public.mark_order_paid(text, text, text)        to service_role;
grant execute on function public.release_order(text, text)                to service_role;
grant execute on function public.release_expired_orders()                 to service_role;

-- trigger functions still run (triggers don't need EXECUTE for the caller)

-- ---------------------------------------------------------------------
-- 14. Product images bucket (public read, admin upload)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public) values ('product-images', 'product-images', true)
  on conflict (id) do nothing;
create policy product_images_admin_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and public.is_admin());
create policy product_images_admin_update on storage.objects for update to authenticated
  using (bucket_id = 'product-images' and public.is_admin());
create policy product_images_admin_delete on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and public.is_admin());

-- =====================================================================
-- AFTER RUNNING: run seed.sql, sign up on the site, then make yourself admin:
--   update public.profiles set role = 'admin'
--   where id = (select id from auth.users where email = 'YOUR_EMAIL');
-- =====================================================================
