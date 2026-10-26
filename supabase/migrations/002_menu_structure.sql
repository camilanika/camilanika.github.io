-- =====================================================================
-- Migration 002: main menus (Minuman, Camilan) and submenus
-- Safe to run on the live database: keeps every product, variant id,
-- stock number and order. Run once in Supabase → SQL Editor.
--
-- Adds
--   menu_categories   main menus shown as big sections + header links
--   menu_sections     submenus inside a main menu (e.g. Coffee Series)
--   products.section_id  which submenu a product belongs to
-- Splits "Cireng Isi" into "Cireng Isi Matang" and "Cireng Isi Frozen"
-- (the Frozen variants move with their stock to the new product).
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------
create table public.menu_categories (
  id            bigint generated always as identity primary key,
  name          text not null,                  -- header link + section name, e.g. 'Minuman'
  slug          text not null unique,           -- page anchor, e.g. 'minuman' -> #minuman
  eyebrow       text,                           -- small label above the heading
  heading       text,                           -- big heading (defaults to name)
  heading_script text,                          -- handwritten part after the heading
  description   text,
  sort_order    integer not null default 0,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create trigger trg_menu_categories_updated before update on public.menu_categories
  for each row execute function public.set_updated_at();

create table public.menu_sections (
  id            bigint generated always as identity primary key,
  category_id   bigint not null references public.menu_categories(id) on delete cascade,
  name          text not null,                  -- e.g. 'Coffee Series'
  slug          text not null unique,
  tagline       text,
  icon          text,                           -- optional emoji for the jump links
  accent        text not null default 'caramel' check (accent in ('caramel','rose','matcha','berry','ocean','charcoal')),
  sort_order    integer not null default 0,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index menu_sections_category_idx on public.menu_sections(category_id);
create trigger trg_menu_sections_updated before update on public.menu_sections
  for each row execute function public.set_updated_at();

alter table public.products add column section_id bigint references public.menu_sections(id) on delete set null;
create index products_section_idx on public.products(section_id);

alter table public.menu_categories enable row level security;
alter table public.menu_sections   enable row level security;
create policy menu_categories_select on public.menu_categories for select to anon, authenticated
  using (is_active or public.is_admin());
create policy menu_categories_admin on public.menu_categories for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy menu_sections_select on public.menu_sections for select to anon, authenticated
  using (is_active or public.is_admin());
create policy menu_sections_admin on public.menu_sections for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- A product is for sale only if it, its submenu and its main menu are all active
create or replace function public.product_on_sale(p_product_id bigint)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.products p
      join public.menu_sections s on s.id = p.section_id
      join public.menu_categories c on c.id = s.category_id
     where p.id = p_product_id and p.is_active and s.is_active and c.is_active);
$$;
revoke execute on function public.product_on_sale(bigint) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Current menu structure
-- ---------------------------------------------------------------------
insert into public.menu_categories (name, slug, eyebrow, heading, heading_script, description, sort_order) values
  ('Minuman', 'minuman', 'Our Menu', 'Coffee & Drinks', 'dalam botol',
   'Dari yang strong sampai yang creamy dan manis, tinggal pilih sesuai mood kamu. Diseduh langsung dari mesin espresso dan pakai susu segar.', 10),
  ('Camilan', 'camilan', 'Camilan', 'Cireng Isi', null,
   'Gurih di luar, nagih di dalam. Beli frozen untuk stok di rumah, atau matang siap santap.', 20);

insert into public.menu_sections (category_id, name, slug, tagline, icon, accent, sort_order)
select c.id, s.name, s.slug, s.tagline, s.icon, s.accent, s.so
from public.menu_categories c
join (values
  ('minuman', 'Coffee Series',      'coffee',            'Rasa kopi yang selalu jadi pilihan.',              '☕', 'caramel', 10),
  ('minuman', 'Chocolate Series',   'choco',             'Cokelat yang selalu bikin hari lebih manis.',      '🍫', 'rose',    20),
  ('minuman', 'Matcha Series',      'matcha',            'Kesegaran matcha, ketenangan di setiap tegukan.',  '🍵', 'matcha',  30),
  ('camilan', 'Cireng Isi Matang',  'cireng-isi-matang', 'Siap santap, tinggal dinikmati.',                  null, 'rose',    10),
  ('camilan', 'Cireng Isi Frozen',  'cireng-isi-frozen', 'Stok di freezer, goreng kapan saja.',              null, 'ocean',   20),
  ('camilan', 'Cireng Kuah Creamy', 'cireng-kuah-creamy','Kuah keju berpadu chili oil, gurih dan pedas.',    null, 'caramel', 30)
) as s(cat, name, slug, tagline, icon, accent, so) on s.cat = c.slug;

-- drinks: map the old series to submenus
update public.products p set section_id = s.id
  from public.menu_sections s
 where s.slug = p.series and p.series in ('coffee','choco','matcha');

-- ---------------------------------------------------------------------
-- 3. Split Cireng Isi into Matang and Frozen (variants keep their ids and stock)
-- ---------------------------------------------------------------------
do $$
declare
  v_old bigint;
  v_new bigint;
begin
  select id into v_old from public.products where slug = 'cireng-isi';
  if v_old is null then return; end if;

  insert into public.products (name, slug, series, subtitle, image_url, attr_names, choices, is_active, sort_order, section_id)
  select 'Cireng Isi Frozen', 'cireng-isi-frozen', 'cireng', 'Beku dalam kemasan vakum. Pilih isian dan kemasan.',
         'img/frozen-pack.jpg', array['Isian','Kemasan'], p.choices, p.is_active, p.sort_order + 1,
         (select id from public.menu_sections where slug = 'cireng-isi-frozen')
    from public.products p where p.id = v_old
  returning id into v_new;

  update public.product_variants
     set product_id = v_new,
         attrs = attrs - 'Kondisi',
         name = regexp_replace(name, ' · Frozen$', ''),
         sku = regexp_replace(coalesce(sku, ''), '-frozen$', '') || '-frozen'
   where product_id = v_old and attrs->>'Kondisi' = 'Frozen';

  update public.product_variants
     set attrs = attrs - 'Kondisi',
         name = regexp_replace(name, ' · Matang$', '')
   where product_id = v_old;

  update public.products
     set name = 'Cireng Isi Matang', subtitle = 'Digoreng fresh, siap santap. Pilih isian dan kemasan.',
         attr_names = array_remove(attr_names, 'Kondisi'),
         section_id = (select id from public.menu_sections where slug = 'cireng-isi-matang')
   where id = v_old;

  -- promos that covered "Cireng Isi" also cover the frozen product
  insert into public.promotion_products (promotion_id, product_id)
  select promotion_id, v_new from public.promotion_products where product_id = v_old
  on conflict do nothing;
end $$;

update public.products set section_id = (select id from public.menu_sections where slug = 'cireng-kuah-creamy')
 where slug = 'cireng-kuah';

-- anything else that was a snack goes to the first Camilan submenu
update public.products set section_id = (select id from public.menu_sections where slug = 'cireng-isi-matang')
 where section_id is null and series = 'cireng';

-- ---------------------------------------------------------------------
-- 4. Menu for the shop page (old 'series' still returned so the current site keeps working until the new one is live)
-- ---------------------------------------------------------------------
create or replace function public.get_menu()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id, 'name', c.name, 'slug', c.slug, 'eyebrow', c.eyebrow, 'heading', c.heading,
        'heading_script', c.heading_script, 'description', c.description,
        'sections', coalesce((
          select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'slug', s.slug, 'tagline', s.tagline,
                                              'icon', s.icon, 'accent', s.accent) order by s.sort_order, s.id)
            from public.menu_sections s where s.category_id = c.id and s.is_active), '[]'::jsonb))
        order by c.sort_order, c.id)
      from public.menu_categories c where c.is_active), '[]'::jsonb),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'name', p.name, 'slug', p.slug, 'series', p.series, 'section_id', p.section_id,
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
      from public.products p where public.product_on_sale(p.id)), '[]'::jsonb),
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
-- 5. Checkout only sells products that are visible on the shop
-- ---------------------------------------------------------------------
do $$
declare v_src text;
begin
  select pg_get_functiondef('public.quote_cart(jsonb, text)'::regprocedure) into v_src;
  if position('product_on_sale' in v_src) = 0 then
    v_src := replace(v_src,
      'where v.id = (e->>''variant_id'')::bigint and v.is_active and p.is_active;',
      'where v.id = (e->>''variant_id'')::bigint and v.is_active and public.product_on_sale(p.id);');
    if position('product_on_sale' in v_src) = 0 then raise exception 'quote_cart patch failed'; end if;
    execute v_src;
  end if;
end $$;

commit;
