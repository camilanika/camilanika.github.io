-- 024: free bottle -> cup switch for S 250 ml drinks, and a "Cup 16 oz + es batu" product (Rp3.000)
-- Run once in the Supabase SQL editor. Safe to run again: both parts skip what already exists.

-- 1) Every drink with an S size gets a free "Kemasan" choice, shown in the shop only when S is picked
--    (the "sizes" field). M and L orders get the default, "Botol".
update public.products p
set choices = p.choices || '[{"label":"Kemasan","options":["Botol","Cup 16 oz + es batu"],"default":0,"sizes":["S"]}]'::jsonb
where 'Ukuran' = any(p.attr_names)
  and exists (select 1 from public.product_variants v where v.product_id = p.id and v.attrs->>'Ukuran' = 'S')
  and not exists (select 1 from jsonb_array_elements(p.choices) c where c->>'label' = 'Kemasan');

-- 2) "Cup 16 oz + es batu" as the last drink: same submenu as the last drink product, sorted after it
insert into public.products (name, slug, series, section_id, subtitle, attr_names, choices, is_active, sort_order)
select 'Cup 16 oz + es batu', 'cup-16oz-es-batu', last_drink.series, last_drink.section_id,
       'Gelas 16 oz berisi es batu, untuk dinikmati langsung', '{}', '[]', true, last_drink.sort_order + 5
from (
  select p.series, p.section_id, p.sort_order
  from public.products p
  where p.slug = 'berrymatcha'
) last_drink
where not exists (select 1 from public.products where slug = 'cup-16oz-es-batu');

insert into public.product_variants (product_id, name, attrs, price, sku, sort_order)
select id, '16 oz', '{}'::jsonb, 3000, 'cup-16oz-es-batu', 1
from public.products
where slug = 'cup-16oz-es-batu'
  and not exists (select 1 from public.product_variants where sku = 'cup-16oz-es-batu');

-- check
select name, choices from public.products where 'Ukuran' = any(attr_names) order by sort_order;
select p.name, v.name, v.price, p.sort_order, p.section_id from public.products p join public.product_variants v on v.product_id = p.id where p.slug in ('berrymatcha', 'cup-16oz-es-batu') order by p.sort_order;
