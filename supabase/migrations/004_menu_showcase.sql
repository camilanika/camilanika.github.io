-- =====================================================================
-- Migration 004: photo showcase + info lines for each main menu, edited in the admin page
-- Safe to run on the live database (and safe to run twice).
--
-- menu_categories gets
--   showcase_layout  'none' | 'row' (swipeable photos above the menu) | 'mosaic' (photo grid beside the menu)
--   showcase_images  [{"url": "...", "caption": "...", "tag": "L", "alt": "..."}]
--   showcase_note    short handwritten line under a mosaic
--   highlights       short info lines under the description
--   tags             pill labels under the description (e.g. fillings)
-- =====================================================================
begin;

alter table public.menu_categories
  add column if not exists showcase_layout text not null default 'none',
  add column if not exists showcase_images jsonb not null default '[]',
  add column if not exists showcase_note text,
  add column if not exists highlights text[] not null default '{}',
  add column if not exists tags text[] not null default '{}';

do $$ begin
  alter table public.menu_categories add constraint menu_categories_showcase_layout_check
    check (showcase_layout in ('none','row','mosaic'));
exception when duplicate_object then null; end $$;

-- What the page showed until now, moved into the database (only if still empty)
update public.menu_categories set
  showcase_layout = 'row',
  showcase_images = '[
    {"url":"img/aren-latte.jpg","caption":"Aren Latte","tag":"L","alt":"Botol Aren Latte 1000 ml"},
    {"url":"img/iced-latte.jpg","caption":"Tinggal tuang es","alt":"Latte botolan dituang ke gelas berisi es"},
    {"url":"img/butterscotch.jpg","caption":"Butterscotch","tag":"M","alt":"Botol Butterscotch Latte 500 ml"},
    {"url":"img/chocolate-row.jpg","caption":"Chocolate","tag":"S","alt":"Deretan botol Chocolate dan Butterscotch Latte 250 ml"},
    {"url":"img/peach-americano.jpg","caption":"Peach Americano","tag":"S","alt":"Botol Peach Americano 250 ml"},
    {"url":"img/bottles-trio.jpg","caption":"Aneka rasa","alt":"Botol Aren Latte, Americano Peach 1 liter dan Salted Caramel Latte"},
    {"url":"img/salted-caramel.jpg","caption":"Salted Caramel","tag":"S","alt":"Botol Salted Caramel Latte 250 ml"}]'::jsonb,
  highlights = array['Extra shot: S Rp2.000 · M Rp4.000 · L Rp8.000','Simpan di kulkas, tahan hingga 7 hari','Tinggal tuang es, langsung nikmat']
where slug = 'minuman' and showcase_images = '[]'::jsonb;

update public.menu_categories set
  showcase_layout = 'mosaic',
  showcase_images = '[
    {"url":"img/cireng-isi.jpg","caption":"Ayam Suwir","alt":"Cireng isi ayam suwir dibelah, terlihat isian"},
    {"url":"img/keju-lumer.jpg","caption":"Keju Lumer","alt":"Cireng isi keju lumer dibelah"},
    {"url":"img/jando-pedas.jpg","caption":"Jando Pedas","alt":"Cireng isi jando pedas dibelah"},
    {"url":"img/frozen-pack.jpg","caption":"Frozen","alt":"Cireng isi frozen dalam kemasan vakum isi 6"},
    {"url":"img/kuah-togo.jpg","caption":"Kuah to-go","alt":"Paket cireng kuah creamy siap bawa dengan kuah keju dan chili oil terpisah"},
    {"url":"img/kuah-real.jpg","caption":"Cireng Kuah Creamy","alt":"Cireng kuah creamy dengan kuah keju, cuanki dan chili oil"}]'::jsonb,
  showcase_note = 'Gurih di luar, nagih di dalam!',
  highlights = array['Frozen tahan lama, goreng kapan saja','Dikemas rapi dan higienis'],
  tags = array['Ayam Suwir Original','Ayam Suwir Pedas','Keju Lumer','Jando Pedas']
where slug = 'camilan' and showcase_images = '[]'::jsonb;

-- Shop menu now includes the showcase
create or replace function public.get_menu()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id, 'name', c.name, 'slug', c.slug, 'eyebrow', c.eyebrow, 'heading', c.heading,
        'heading_script', c.heading_script, 'description', c.description,
        'showcase_layout', c.showcase_layout, 'showcase_images', c.showcase_images, 'showcase_note', c.showcase_note,
        'highlights', to_jsonb(c.highlights), 'tags', to_jsonb(c.tags),
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

commit;
