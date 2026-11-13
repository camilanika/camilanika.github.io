-- =====================================================================
-- Migration 021: the menu is grouped by series only; series descriptions; "Semua" description; photo gallery
-- Safe to run on the live database (and safe to run twice).
--
-- Since the Nov 2026 redesign the shop shows one menu grid with a tab per series (menu_sections), so main menus
-- (menu_categories) are no longer shown anywhere and no longer edited in the admin page.
--   * menu_sections gets description, highlights (info lines) and tags (round labels), shown under its tab.
--     Filled once from the old main-menu texts, rewritten per series.
--   * Series are ordered as one list (sort_order across all of them).
--   * menu_categories stays as an internal table only, because existing database functions (get_menu,
--     product_on_sale) join through it. Every main menu is switched on; a series that was hidden only because
--     its main menu was hidden is hidden itself instead, so nothing new appears in the shop.
--     A new series is put in a main menu automatically (trigger), so the admin page never asks for one.
--   * shop_settings: menu_intro + menu_highlights (the "Semua" tab), gallery (photo strip under the hero),
--     filled once from the old per-menu photo showcases.
--   * get_storefront() also returns series details, the Semua texts and the gallery.
--   * GoFood is no longer used: a testimonial can't be marked as from GoFood any more (old ones become 'lainnya').
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. Series details
-- ---------------------------------------------------------------------
alter table public.menu_sections
  add column if not exists description text,
  add column if not exists highlights  text[] not null default '{}',
  add column if not exists tags        text[] not null default '{}';

-- texts per series (only where nothing is written yet; the admin can change them in Series)
update public.menu_sections s set description = v.d, highlights = v.h, tags = v.t
  from (values
    ('coffee',
     'Diseduh dari mesin espresso dengan susu segar. Dari Americano yang strong sampai latte yang creamy dan manis, tinggal pilih sesuai mood kamu.',
     array['Extra shot: S Rp2.000 · M Rp4.000 · L Rp8.000', 'Simpan di kulkas, tahan hingga 7 hari', 'Tinggal tuang es, langsung nikmat'],
     array['S · 250 ml', 'M · 500 ml', 'L · 1000 ml']),
    ('choco',
     'Coklat pekat yang creamy dan manisnya pas. Mau yang klasik, yang segar dengan jeruk, atau yang dipadu kopi.',
     array['Simpan di kulkas, tahan hingga 7 hari', 'Tinggal tuang es, langsung nikmat'],
     '{}'::text[]),
    ('matcha',
     'Matcha lembut dengan susu segar. Mau lebih nendang? Coba Dirty Matcha dengan espresso, atau Berry Matcha yang manis segar.',
     array['Simpan di kulkas, tahan hingga 7 hari', 'Tinggal tuang es, langsung nikmat'],
     '{}'::text[]),
    ('cireng-isi-matang',
     'Digoreng fresh, renyah di luar dan nagih di dalam. Siap santap, tinggal dinikmati.',
     array['Dikemas rapi dan higienis'],
     array['Ayam Suwir Original', 'Ayam Suwir Pedas', 'Keju Lumer', 'Jando Pedas']),
    ('cireng-isi-frozen',
     'Cireng isi beku dalam kemasan vakum untuk stok di freezer. Goreng kapan saja, kapan pun lagi pengen.',
     array['Frozen tahan lama, goreng kapan saja', 'Dikemas rapi dan higienis'],
     array['Ayam Suwir Original', 'Ayam Suwir Pedas', 'Keju Lumer', 'Jando Pedas']),
    ('cireng-kuah-creamy',
     'Cireng dengan kuah keju yang creamy dan chili oil: gurih, pedas, bikin nagih.',
     array['Kuah keju dan chili oil dikemas terpisah, siap dibawa'],
     '{}'::text[])
  ) as v(slug, d, h, t)
 where s.slug = v.slug and s.description is null;
-- any other series: start from its short tagline
update public.menu_sections set description = tagline where description is null and tagline is not null;

-- ---------------------------------------------------------------------
-- 2. Main menus become internal
-- ---------------------------------------------------------------------
-- a series hidden only because its main menu was hidden: hide the series itself, then switch every main menu on
do $$
begin
  if exists (select 1 from public.menu_categories where not is_active) then
    update public.menu_sections s set is_active = false
      from public.menu_categories c where c.id = s.category_id and not c.is_active;
    update public.menu_categories set is_active = true where not is_active;
  end if;
end $$;

-- one order for all series: the order the shop showed until now (main menu, then series); Paket Hemat stays first
do $$
begin
  if not exists (select 1 from public.menu_sections s join public.menu_sections s2 on s2.id <> s.id and s2.sort_order = s.sort_order
                  where s.slug <> 'paket-hemat' and s2.slug <> 'paket-hemat') then
    return;   -- already one clean list (second run)
  end if;
  update public.menu_sections s set sort_order = x.n * 10
    from (select s2.id, row_number() over (order by c.sort_order, c.id, s2.sort_order, s2.id) as n
            from public.menu_sections s2 join public.menu_categories c on c.id = s2.category_id
           where s2.slug <> 'paket-hemat') x
   where s.id = x.id;
end $$;

-- a new series without a main menu goes in the one the last series is in (or a new internal "Menu")
create or replace function public.menu_section_default_category()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.category_id is null then
    select s.category_id into new.category_id from public.menu_sections s
      join public.menu_categories c on c.id = s.category_id
     where c.slug <> 'paket' order by s.sort_order desc, s.id desc limit 1;
    if new.category_id is null then
      insert into public.menu_categories (name, slug, sort_order) values ('Menu', 'menu', 10)
      on conflict (slug) do update set name = excluded.name
      returning id into new.category_id;
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.menu_section_default_category() from public, anon, authenticated;
drop trigger if exists trg_menu_sections_default_category on public.menu_sections;
create trigger trg_menu_sections_default_category before insert on public.menu_sections
  for each row execute function public.menu_section_default_category();

-- ---------------------------------------------------------------------
-- 3. "Semua" tab + photo gallery
-- ---------------------------------------------------------------------
alter table public.shop_settings
  add column if not exists menu_intro      text,
  add column if not exists menu_highlights text[] not null default '{}',
  add column if not exists gallery         jsonb not null default '[]';   -- [{"url": "...", "caption": "...", "alt": "..."}]

update public.shop_settings set
  menu_intro = 'Kopi, coklat dan matcha dalam botol, plus cireng isi homemade. Semua dibuat fresh setiap hari tanpa pengawet, tinggal pilih dan kami antar.',
  menu_highlights = array['Tanpa pengawet, dibuat fresh setiap hari', 'Free delivery area Bukit Cimanggu City']
 where id = 1 and menu_intro is null;

-- gallery: the photos of the old per-menu showcases, drinks first, then cireng (only if the gallery is still empty)
update public.shop_settings set gallery = coalesce((
    select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('url', i->>'url', 'caption', i->>'caption', 'alt', coalesce(i->>'alt', i->>'caption'))) order by (c.slug = 'minuman') desc, c.sort_order, c.id, o.n)
      from public.menu_categories c, jsonb_array_elements(c.showcase_images) with ordinality o(i, n)
     where coalesce(i->>'url', '') <> ''), '[]'::jsonb)
 where id = 1 and gallery = '[]'::jsonb;

-- ---------------------------------------------------------------------
-- 4. GoFood is gone: testimonial sources without it
-- ---------------------------------------------------------------------
update public.testimonials set source = 'lainnya' where source = 'gofood';
alter table public.testimonials drop constraint if exists testimonials_source_check;
alter table public.testimonials add constraint testimonials_source_check check (source in ('instagram','whatsapp','google','lainnya'));

-- ---------------------------------------------------------------------
-- 5. get_storefront(): + series details, Semua texts, gallery
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
         group by oi.product_id order by sold desc, oi.product_id limit 4) bs), '[]'::jsonb),
    'series', coalesce((
      select jsonb_agg(jsonb_build_object('id', ms.id, 'slug', ms.slug, 'sort_order', ms.sort_order, 'description', ms.description,
                                          'highlights', to_jsonb(ms.highlights), 'tags', to_jsonb(ms.tags)) order by ms.sort_order, ms.id)
        from public.menu_sections ms where ms.is_active), '[]'::jsonb),
    'menu', jsonb_build_object('intro', (select menu_intro from s), 'highlights', to_jsonb(coalesce((select menu_highlights from s), '{}'::text[]))),
    'gallery', coalesce((select gallery from s), '[]'::jsonb));
$$;
revoke execute on function public.get_storefront() from public;
grant execute on function public.get_storefront() to anon, authenticated, service_role;

commit;
