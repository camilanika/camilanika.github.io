-- =====================================================================
-- Migration 020: Paket Hemat (bundles), Testimoni pelanggan, Best Seller
-- Safe to run on the live database (and safe to run twice).
--
-- Paket Hemat
--   A paket is a normal product with one variant ("Paket", the paket price), so cart, checkout, stock,
--   payment, vouchers, loyalty and Cashflow treat it like any other menu item and nothing in create_order
--   changes. It lives in the "Paket Hemat" main menu, which the shop shows as its own section.
--   products.is_bundle marks it; bundle_items lists what is inside (variant + quantity), which the shop
--   shows and uses for the "normal price" and "Hemat X%" label.
--   Admin: admin_list_bundles / admin_save_bundle / admin_move_bundle / admin_delete_bundle (Paket Hemat page in admin.html).
--
-- Testimoni pelanggan
--   testimonials: a customer photo or review screenshot and/or the customer's words, who said it, where
--   (Instagram, WhatsApp, GoFood, Google), an optional link, shown or hidden, and an order.
--   Photos go in the existing public 'product-images' bucket (folder testimoni/), admins only.
--   shop_settings gets the section's switch, title, subtitle, how many to show and the Instagram handle.
--
-- get_storefront(): one public call for the shop page with pakets, testimonials and the best sellers
-- (most items sold in real paid orders over the last 30 days; no customer data leaves the database).
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. Paket Hemat
-- ---------------------------------------------------------------------
alter table public.products
  add column if not exists is_bundle    boolean not null default false,
  add column if not exists bundle_badge text;            -- short label on the card, e.g. 'Untuk 4 orang'

create table if not exists public.bundle_items (
  id          bigint generated always as identity primary key,
  bundle_id   bigint not null references public.products(id) on delete cascade,
  variant_id  bigint not null references public.product_variants(id) on delete cascade,
  quantity    integer not null default 1 check (quantity between 1 and 20),
  sort_order  integer not null default 0,
  unique (bundle_id, variant_id)
);
create index if not exists bundle_items_bundle_idx on public.bundle_items(bundle_id);
create index if not exists bundle_items_variant_idx on public.bundle_items(variant_id);

alter table public.bundle_items enable row level security;
drop policy if exists bundle_items_admin on public.bundle_items;
create policy bundle_items_admin on public.bundle_items for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
revoke all on public.bundle_items from anon;

-- the main menu + submenu every paket goes in (only if missing; the admin may rename them in Menu)
insert into public.menu_categories (name, slug, eyebrow, heading, description, sort_order)
values ('Paket Hemat', 'paket', 'Lebih hemat', 'Paket Ngopi + Nyemil', 'Kopi dan camilan favorit dalam satu paket.', 0)
on conflict (slug) do nothing;
insert into public.menu_sections (category_id, name, slug, accent, sort_order)
select c.id, 'Paket Hemat', 'paket-hemat', 'rose', 0 from public.menu_categories c where c.slug = 'paket'
on conflict (slug) do nothing;

-- Create or update a paket. p_items: [{"variant_id": 12, "quantity": 1}, ...]. Returns the paket's product id.
create or replace function public.admin_save_bundle(
  p_id bigint, p_name text, p_subtitle text, p_image_url text, p_price integer,
  p_badge text, p_items jsonb, p_active boolean, p_sort_order integer default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_cat bigint; v_sec bigint; v_id bigint; v_slug text;
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  p_name := nullif(btrim(coalesce(p_name, '')), '');
  if p_name is null then raise exception 'BUNDLE_NAME_REQUIRED'; end if;
  if p_price is null or p_price < 0 then raise exception 'BUNDLE_PRICE_INVALID'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'BUNDLE_ITEMS_REQUIRED';
  end if;
  if exists (select 1 from jsonb_array_elements(p_items) e
              where jsonb_typeof(e) <> 'object' or (e->>'variant_id') !~ '^\d+$'
                 or coalesce(e->>'quantity', '1') !~ '^\d+$' or coalesce((e->>'quantity')::int, 1) not between 1 and 20) then
    raise exception 'BUNDLE_ITEM_INVALID';
  end if;
  -- every item is an existing variant of a normal (non-paket) product, listed once
  if exists (select 1 from jsonb_array_elements(p_items) e
               left join public.product_variants v on v.id = (e->>'variant_id')::bigint
               left join public.products p on p.id = v.product_id
              where v.id is null or p.is_bundle) then
    raise exception 'BUNDLE_ITEM_INVALID';
  end if;
  if (select count(distinct e->>'variant_id') from jsonb_array_elements(p_items) e) <> jsonb_array_length(p_items) then
    raise exception 'BUNDLE_ITEM_DUPLICATE';
  end if;

  -- the Paket Hemat menu (recreated if an admin deleted it)
  select s.id into v_sec from public.menu_sections s where s.slug = 'paket-hemat';
  if v_sec is null then
    select c.id into v_cat from public.menu_categories c where c.slug = 'paket';
    if v_cat is null then
      insert into public.menu_categories (name, slug, eyebrow, heading, sort_order)
      values ('Paket Hemat', 'paket', 'Lebih hemat', 'Paket Ngopi + Nyemil', 0) returning id into v_cat;
    end if;
    insert into public.menu_sections (category_id, name, slug, accent) values (v_cat, 'Paket Hemat', 'paket-hemat', 'rose')
    returning id into v_sec;
  end if;

  if p_id is null then
    v_slug := 'paket-' || coalesce(nullif(trim(both '-' from regexp_replace(lower(p_name), '[^a-z0-9]+', '-', 'g')), ''), 'baru')
              || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 5);
    insert into public.products (name, slug, series, section_id, subtitle, image_url, attr_names, choices,
                                 is_active, sort_order, is_bundle, bundle_badge)
    values (p_name, v_slug, 'paket', v_sec, nullif(btrim(coalesce(p_subtitle, '')), ''), nullif(btrim(coalesce(p_image_url, '')), ''),
            '{}', '[]', coalesce(p_active, true),
            coalesce(p_sort_order, (select coalesce(max(sort_order), 0) + 10 from public.products where is_bundle)),
            true, nullif(btrim(coalesce(p_badge, '')), ''))
    returning id into v_id;
    insert into public.product_variants (product_id, name, attrs, price) values (v_id, 'Paket', '{}', p_price);
  else
    update public.products set
      name = p_name, subtitle = nullif(btrim(coalesce(p_subtitle, '')), ''), image_url = nullif(btrim(coalesce(p_image_url, '')), ''),
      bundle_badge = nullif(btrim(coalesce(p_badge, '')), ''), is_active = coalesce(p_active, is_active),
      sort_order = coalesce(p_sort_order, sort_order),
      section_id = coalesce(section_id, v_sec)
    where id = p_id and is_bundle
    returning id into v_id;
    if v_id is null then raise exception 'BUNDLE_NOT_FOUND'; end if;
    update public.product_variants set price = p_price, is_active = true where product_id = v_id;
    if not found then
      insert into public.product_variants (product_id, name, attrs, price) values (v_id, 'Paket', '{}', p_price);
    end if;
  end if;

  delete from public.bundle_items where bundle_id = v_id;
  insert into public.bundle_items (bundle_id, variant_id, quantity, sort_order)
  select v_id, (e->>'variant_id')::bigint, coalesce((e->>'quantity')::int, 1), t.ord::int
    from jsonb_array_elements(p_items) with ordinality t(e, ord);
  return v_id;
end $$;

-- Delete a paket. Past orders keep their item names and totals (order_items are snapshots).
create or replace function public.admin_delete_bundle(p_id bigint)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  delete from public.products where id = p_id and is_bundle;
  if not found then raise exception 'BUNDLE_NOT_FOUND'; end if;
  return true;
end $$;

-- For the admin page: every paket with its items (hidden ones too), and every item a paket can contain
create or replace function public.admin_list_bundles()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  return jsonb_build_object(
    'bundles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'name', p.name, 'subtitle', p.subtitle, 'image_url', p.image_url, 'badge', p.bundle_badge,
        'is_active', p.is_active, 'sort_order', p.sort_order, 'on_sale', public.product_on_sale(p.id),
        'price', (select min(v.price) from public.product_variants v where v.product_id = p.id),
        'items', coalesce((
          select jsonb_agg(jsonb_build_object(
            'variant_id', bi.variant_id, 'quantity', bi.quantity, 'product', ip.name, 'variant', iv.name,
            'price', iv.price, 'active', iv.is_active and public.product_on_sale(ip.id)) order by bi.sort_order, bi.id)
          from public.bundle_items bi
          join public.product_variants iv on iv.id = bi.variant_id
          join public.products ip on ip.id = iv.product_id
          where bi.bundle_id = p.id), '[]'::jsonb))
        order by p.sort_order, p.id)
      from public.products p where p.is_bundle), '[]'::jsonb),
    'options', coalesce((
      select jsonb_agg(jsonb_build_object('variant_id', v.id, 'product', p.name, 'variant', v.name, 'price', v.price,
                                          'active', v.is_active and public.product_on_sale(p.id))
                       order by p.sort_order, p.id, v.sort_order, v.id)
        from public.product_variants v join public.products p on p.id = v.product_id
       where not p.is_bundle), '[]'::jsonb));
end $$;

-- Move a paket up or down among the pakets (p_dir -1 / 1)
create or replace function public.admin_move_bundle(p_id bigint, p_dir integer)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_ids bigint[]; v_i int; v_j int;
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  select array_agg(id order by sort_order, id) into v_ids from public.products where is_bundle;
  v_i := array_position(v_ids, p_id);
  if v_i is null then raise exception 'BUNDLE_NOT_FOUND'; end if;
  v_j := v_i + case when p_dir < 0 then -1 else 1 end;
  if v_j < 1 or v_j > array_length(v_ids, 1) then return false; end if;
  v_ids[v_i] := v_ids[v_j]; v_ids[v_j] := p_id;
  update public.products p set sort_order = x.ord * 10 from unnest(v_ids) with ordinality x(id, ord) where p.id = x.id;
  return true;
end $$;

-- ---------------------------------------------------------------------
-- 2. Testimoni pelanggan
-- ---------------------------------------------------------------------
create table if not exists public.testimonials (
  id          bigint generated always as identity primary key,
  image_url   text,                                   -- customer photo or review screenshot
  quote       text,                                   -- the customer's own words, copied from a real message
  author      text,                                   -- name or @handle, as the customer agreed to be shown
  source      text not null default 'instagram' check (source in ('instagram','whatsapp','gofood','google','lainnya')),
  link_url    text check (link_url is null or link_url ~* '^https://'),
  is_visible  boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (coalesce(btrim(image_url), '') <> '' or coalesce(btrim(quote), '') <> '')
);
drop trigger if exists trg_testimonials_updated on public.testimonials;
create trigger trg_testimonials_updated before update on public.testimonials
  for each row execute function public.set_updated_at();

alter table public.testimonials enable row level security;
drop policy if exists testimonials_select on public.testimonials;
create policy testimonials_select on public.testimonials for select to anon, authenticated
  using (is_visible or public.is_admin());
drop policy if exists testimonials_admin on public.testimonials;
create policy testimonials_admin on public.testimonials for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- section settings (admin page: Testimoni → Pengaturan; Paket Hemat → Judul)
alter table public.shop_settings
  add column if not exists testi_enabled   boolean not null default true,
  add column if not exists testi_title     text not null default 'Kata mereka tentang CamilaNika',
  add column if not exists testi_subtitle  text,
  add column if not exists testi_limit     integer not null default 8,
  add column if not exists testi_instagram text default 'camilanika.food',
  add column if not exists paket_title     text not null default 'Paket Ngopi + Nyemil',
  add column if not exists paket_subtitle  text;
alter table public.shop_settings drop constraint if exists shop_settings_testi_limit_check;
alter table public.shop_settings add constraint shop_settings_testi_limit_check check (testi_limit between 1 and 24);

-- ---------------------------------------------------------------------
-- 3. One public call for the new storefront sections
-- ---------------------------------------------------------------------
create or replace function public.get_storefront()
returns jsonb language sql stable security definer set search_path = public as $$
  with s as (select * from public.shop_settings where id = 1),
  avail as (   -- null = unlimited, otherwise what is left for new customers
    select v.id, v.product_id, v.price, v.name, v.is_active,
           case when coalesce(i.unlimited, false) then null else greatest(coalesce(i.stock, 0) - coalesce(i.reserved, 0), 0) end as left_n
      from public.product_variants v left join public.inventory i on i.variant_id = v.id)
  select jsonb_build_object(
    'paket', jsonb_build_object('title', (select paket_title from s), 'subtitle', (select paket_subtitle from s)),
    'bundles', coalesce((
      select jsonb_agg(b order by (b->>'sort_order')::int, (b->>'id')::bigint) from (
        select jsonb_build_object(
          'id', p.id, 'name', p.name, 'subtitle', p.subtitle, 'image_url', p.image_url, 'badge', p.bundle_badge,
          'sort_order', p.sort_order, 'variant_id', bv.id, 'price', bv.price,
          'normal_price', (select coalesce(sum(a.price * bi.quantity), 0) from public.bundle_items bi join avail a on a.id = bi.variant_id where bi.bundle_id = p.id),
          'items', coalesce((select jsonb_agg(jsonb_build_object('name', ip.name || case when a.name not in ('Default', 'Paket', '') then ' ' || a.name else '' end,
                                                                 'quantity', bi.quantity) order by bi.sort_order, bi.id)
                               from public.bundle_items bi join avail a on a.id = bi.variant_id join public.products ip on ip.id = a.product_id
                              where bi.bundle_id = p.id), '[]'::jsonb),
          -- sold out when the paket itself or anything inside it can't be ordered now
          'available', (bv.left_n is null or bv.left_n > 0)
                       and not exists (select 1 from public.bundle_items bi join avail a on a.id = bi.variant_id
                                        where bi.bundle_id = p.id
                                          and (not a.is_active or not public.product_on_sale(a.product_id) or (a.left_n is not null and a.left_n < bi.quantity)))) as b
          from public.products p
          join lateral (select * from avail a where a.product_id = p.id and a.is_active order by a.id limit 1) bv on true
         where p.is_bundle and public.product_on_sale(p.id)
           and exists (select 1 from public.bundle_items bi where bi.bundle_id = p.id)) x), '[]'::jsonb),
    'testimonials', case when coalesce((select testi_enabled from s), true) then coalesce((
      select jsonb_agg(jsonb_build_object('id', t.id, 'image_url', t.image_url, 'quote', t.quote, 'author', t.author,
                                          'source', t.source, 'link_url', t.link_url) order by t.sort_order, t.id)
        from (select * from public.testimonials where is_visible order by sort_order, id
              limit coalesce((select testi_limit from s), 8)) t), '[]'::jsonb) else '[]'::jsonb end,
    'testi', jsonb_build_object('enabled', coalesce((select testi_enabled from s), true), 'title', (select testi_title from s),
                                'subtitle', (select testi_subtitle from s), 'instagram', (select testi_instagram from s)),
    'best_sellers', coalesce((
      select jsonb_agg(product_id order by sold desc, product_id) from (
        select oi.product_id, sum(oi.quantity) as sold
          from public.order_items oi join public.orders o on o.id = oi.order_id
         where o.status in ('paid', 'processing', 'ready', 'shipping', 'completed')
           and o.classification = 'real'
           and coalesce(o.paid_at, o.created_at) > now() - interval '30 days'
           and oi.product_id is not null and public.product_on_sale(oi.product_id)
         group by oi.product_id order by sold desc, oi.product_id limit 4) bs), '[]'::jsonb));
$$;
revoke execute on function public.get_storefront() from public;
grant execute on function public.get_storefront() to anon, authenticated, service_role;

revoke execute on function public.admin_save_bundle(bigint, text, text, text, integer, text, jsonb, boolean, integer) from public, anon;
revoke execute on function public.admin_delete_bundle(bigint) from public, anon;
revoke execute on function public.admin_list_bundles() from public, anon;
revoke execute on function public.admin_move_bundle(bigint, integer) from public, anon;
grant execute on function public.admin_save_bundle(bigint, text, text, text, integer, text, jsonb, boolean, integer) to authenticated;
grant execute on function public.admin_delete_bundle(bigint) to authenticated;
grant execute on function public.admin_list_bundles() to authenticated;
grant execute on function public.admin_move_bundle(bigint, integer) to authenticated;

commit;
