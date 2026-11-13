-- =====================================================================
-- Tests for migration 020: Paket Hemat (bundles), Testimoni pelanggan and the storefront call
-- Run with tests/db/run.sh, which builds a fresh database from the repo, then runs this file.
-- =====================================================================
\set ON_ERROR_STOP 1
set client_min_messages = warning;
\o /dev/null

create schema t;
create table t.results (n serial primary key, id text not null, name text not null, ok boolean not null, info text);
create table t.vars (k text primary key, v text);
grant usage on schema t to anon, authenticated;
grant all on all tables in schema t to anon, authenticated;
grant all on all sequences in schema t to anon, authenticated;
create function t.ok(id text, c boolean, name text, info text default null) returns void language sql as $$
  insert into t.results (id, name, ok, info) values (id, name, coalesce(c, false), info) $$;
create function t.v(k text) returns text language sql stable as $$ select v from t.vars where vars.k = $1 $$;
grant execute on all functions in schema t to anon, authenticated;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@test.local'),
  ('00000000-0000-0000-0000-00000000000c', 'customer@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-00000000000a';
update public.inventory set unlimited = true;

-- two items from two different normal products
insert into t.vars
select 'v1', min(v.id)::text from public.product_variants v join public.products p on p.id = v.product_id where p.id = (select min(id) from public.products)
union all
select 'v2', min(v.id)::text from public.product_variants v join public.products p on p.id = v.product_id where p.id = (select max(id) from public.products);
insert into t.vars select 'normal', ((select price from public.product_variants where id = t.v('v1')::bigint) * 2
                                    + (select price from public.product_variants where id = t.v('v2')::bigint))::text;

-- ---------------------------------------------------------------- PK-01 only admins manage pakets
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
set local role authenticated;
do $$ begin
  perform public.admin_save_bundle(null, 'Hack', null, null, 1, null, '[{"variant_id":1}]', true);
  perform t.ok('PK-01', false, 'customer cannot create a paket', 'accepted');
exception when others then perform t.ok('PK-01', sqlerrm = 'NOT_ADMIN', 'customer cannot create a paket', sqlerrm);
end $$;
do $$ begin
  insert into public.bundle_items (bundle_id, variant_id) values (1, 1);
  perform t.ok('PK-01', false, 'customer cannot write bundle_items', 'accepted');
exception when others then perform t.ok('PK-01', true, 'customer cannot write bundle_items', null);
end $$;
commit;

-- ---------------------------------------------------------------- PK-02 admin creates a paket
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
set local role authenticated;
insert into t.vars select 'paket', public.admin_save_bundle(null, 'Paket Mager', '1 kopi + 1 cireng', null, 30000, 'Hemat',
  jsonb_build_array(jsonb_build_object('variant_id', t.v('v1')::bigint, 'quantity', 2), jsonb_build_object('variant_id', t.v('v2')::bigint)), true)::text;
do $$ begin
  perform public.admin_save_bundle(null, '  ', null, null, 1000, null, '[{"variant_id":1}]', true);
  perform t.ok('PK-02', false, 'name is required', 'accepted');
exception when others then perform t.ok('PK-02', sqlerrm = 'BUNDLE_NAME_REQUIRED', 'name is required', sqlerrm);
end $$;
do $$ begin
  perform public.admin_save_bundle(null, 'X', null, null, 1000, null, '[]', true);
  perform t.ok('PK-02', false, 'at least one item is required', 'accepted');
exception when others then perform t.ok('PK-02', sqlerrm = 'BUNDLE_ITEMS_REQUIRED', 'at least one item is required', sqlerrm);
end $$;
do $$ begin
  perform public.admin_save_bundle(null, 'X', null, null, 1000, null, '[{"variant_id":999999}]', true);
  perform t.ok('PK-02', false, 'unknown variant is refused', 'accepted');
exception when others then perform t.ok('PK-02', sqlerrm = 'BUNDLE_ITEM_INVALID', 'unknown variant is refused', sqlerrm);
end $$;
do $$ begin
  perform public.admin_save_bundle(null, 'X', null, null, 1000, null, jsonb_build_array(jsonb_build_object('variant_id', t.v('v1')::bigint), jsonb_build_object('variant_id', t.v('v1')::bigint)), true);
  perform t.ok('PK-02', false, 'the same item twice is refused', 'accepted');
exception when others then perform t.ok('PK-02', sqlerrm = 'BUNDLE_ITEM_DUPLICATE', 'the same item twice is refused', sqlerrm);
end $$;
do $$ begin
  perform public.admin_save_bundle(null, 'X', null, null, 1000, null, jsonb_build_array(jsonb_build_object('variant_id',
    (select id from public.product_variants where product_id = t.v('paket')::bigint))), true);
  perform t.ok('PK-02', false, 'a paket cannot contain another paket', 'accepted');
exception when others then perform t.ok('PK-02', sqlerrm = 'BUNDLE_ITEM_INVALID', 'a paket cannot contain another paket', sqlerrm);
end $$;
do $$ begin
  perform public.admin_save_bundle(null, 'X', null, null, -5, null, '[{"variant_id":1}]', true);
  perform t.ok('PK-02', false, 'negative price is refused', 'accepted');
exception when others then perform t.ok('PK-02', sqlerrm = 'BUNDLE_PRICE_INVALID', 'negative price is refused', sqlerrm);
end $$;
select t.ok('PK-02', jsonb_array_length(public.admin_list_bundles()->'bundles') = 1 and (public.admin_list_bundles()->'bundles'->0->>'price')::int = 30000
                     and jsonb_array_length(public.admin_list_bundles()->'bundles'->0->'items') = 2, 'admin list shows the paket with price and 2 items');
select t.ok('PK-02', not exists (select 1 from jsonb_array_elements(public.admin_list_bundles()->'options') o
                                  where (o->>'variant_id')::bigint in (select id from public.product_variants where product_id = t.v('paket')::bigint)),
            'a paket is not offered as an item of another paket');
insert into t.vars select 'paket2', public.admin_save_bundle(null, 'Paket Dua', null, null, 10000, null, jsonb_build_array(jsonb_build_object('variant_id', t.v('v2')::bigint)), true)::text;
select t.ok('PK-02', public.admin_move_bundle(t.v('paket2')::bigint, -1), 'move up');
select t.ok('PK-02', (public.admin_list_bundles()->'bundles'->0->>'id')::bigint = t.v('paket2')::bigint, 'move up puts the second paket first');
select t.ok('PK-02', public.admin_delete_bundle(t.v('paket2')::bigint), 'admin deletes a paket nobody ordered');
commit;
select t.ok('PK-02', (select is_bundle and series = 'paket' and section_id = (select id from public.menu_sections where slug = 'paket-hemat')
                        from public.products where id = t.v('paket')::bigint), 'paket is a product in the Paket Hemat menu');
select t.ok('PK-02', (select count(*) = 1 and min(price) = 30000 from public.product_variants where product_id = t.v('paket')::bigint),
            'paket has one variant with the paket price');

-- ---------------------------------------------------------------- PK-03 the shop sees it, with the normal price
begin;
set local role anon;
select t.ok('PK-03', jsonb_array_length(public.get_storefront()->'bundles') = 1, 'guest sees the paket');
select t.ok('PK-03', (public.get_storefront()->'bundles'->0->>'normal_price')::int = t.v('normal')::int, 'normal price = sum of items × quantity',
            public.get_storefront()->'bundles'->0->>'normal_price');
select t.ok('PK-03', (public.get_storefront()->'bundles'->0->>'available')::boolean, 'paket is available');
select t.ok('PK-03', exists (select 1 from jsonb_array_elements(public.get_menu()->'products') p where (p->>'id')::bigint = t.v('paket')::bigint),
            'paket is in get_menu, so cart and checkout work unchanged');
commit;

-- ---------------------------------------------------------------- PK-04 an item sold out makes the paket sold out
update public.inventory set unlimited = false, stock = 1, reserved = 0 where variant_id = t.v('v1')::bigint;   -- paket needs 2
select t.ok('PK-04', not (public.get_storefront()->'bundles'->0->>'available')::boolean, 'not enough of an item: paket shows sold out');
update public.inventory set unlimited = true where variant_id = t.v('v1')::bigint;
select t.ok('PK-04', (public.get_storefront()->'bundles'->0->>'available')::boolean, 'item back in stock: paket available again');

-- ---------------------------------------------------------------- PK-05 checkout charges the paket price
insert into t.vars select 'order', public.create_order('00000000-0000-0000-0000-00000000000c',
  jsonb_build_array(jsonb_build_object('variant_id', (select id from public.product_variants where product_id = t.v('paket')::bigint), 'quantity', 1)),
  null, 'Cust', '081234567890')->>'order_number';
select t.ok('PK-05', (select subtotal from public.orders where order_number = t.v('order')) = 30000, 'order subtotal is the paket price',
            (select subtotal::text from public.orders where order_number = t.v('order')));

-- ---------------------------------------------------------------- PK-06 hidden paket disappears; edit keeps the id
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
set local role authenticated;
select t.ok('PK-06', public.admin_save_bundle(t.v('paket')::bigint, 'Paket Mager 2', null, null, 28000, null,
  jsonb_build_array(jsonb_build_object('variant_id', t.v('v2')::bigint)), false) = t.v('paket')::bigint, 'edit keeps the same paket');
commit;
select t.ok('PK-06', jsonb_array_length(public.get_storefront()->'bundles') = 0, 'hidden paket is not in the shop');
select t.ok('PK-06', (select count(*) from public.bundle_items where bundle_id = t.v('paket')::bigint) = 1, 'items replaced on save');

-- ---------------------------------------------------------------- PK-07 best sellers: real paid orders only
update public.orders set status = 'paid', paid_at = now(), classification = 'mock' where order_number = t.v('order');
select t.ok('PK-07', jsonb_array_length(public.get_storefront()->'best_sellers') = 0, 'test (mock) orders are not counted');
update public.orders set classification = 'real' where order_number = t.v('order');
update public.products set is_active = true where id = t.v('paket')::bigint;
select t.ok('PK-07', public.get_storefront()->'best_sellers' = jsonb_build_array(t.v('paket')::bigint), 'real paid order counts',
            (public.get_storefront()->'best_sellers')::text);
select t.ok('PK-07', not exists (select 1 from jsonb_object_keys(public.get_storefront()) k where k in ('orders', 'customers')), 'no customer data in the storefront');

-- ---------------------------------------------------------------- TS-01 testimonials
insert into public.testimonials (quote, author, source, sort_order) values ('Enak banget latte-nya', '@nika', 'instagram', 2);
insert into public.testimonials (image_url, author, source, is_visible, sort_order) values ('https://x.test/a.jpg', 'Budi', 'gofood', false, 1);
insert into public.testimonials (image_url, source, sort_order) values ('https://x.test/b.jpg', 'whatsapp', 1);
do $$ begin
  insert into public.testimonials (author) values ('kosong');
  perform t.ok('TS-01', false, 'a testimonial needs a photo or words', 'accepted');
exception when check_violation then perform t.ok('TS-01', true, 'a testimonial needs a photo or words', null);
end $$;
do $$ begin
  insert into public.testimonials (quote, link_url) values ('x', 'javascript:alert(1)');
  perform t.ok('TS-01', false, 'links must be https', 'accepted');
exception when check_violation then perform t.ok('TS-01', true, 'links must be https', null);
end $$;
begin;
set local role anon;
select t.ok('TS-01', (select count(*) from public.testimonials) = 2, 'guest reads only visible testimonials');
select t.ok('TS-01', jsonb_array_length(public.get_storefront()->'testimonials') = 2
                     and public.get_storefront()->'testimonials'->0->>'source' = 'whatsapp', 'storefront: visible ones, in order');
do $$ begin
  insert into public.testimonials (quote) values ('spam');
  perform t.ok('TS-01', false, 'guest cannot add a testimonial', 'accepted');
exception when others then perform t.ok('TS-01', true, 'guest cannot add a testimonial', null);
end $$;
commit;
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
set local role authenticated;
do $$ begin
  update public.testimonials set is_visible = true;
  perform t.ok('TS-01', (select count(*) from public.testimonials where author = 'Budi' and is_visible) = 0, 'customer cannot show a hidden testimonial', null);
exception when others then perform t.ok('TS-01', true, 'customer cannot show a hidden testimonial', null);
end $$;
commit;
update public.shop_settings set testi_limit = 1 where id = 1;
select t.ok('TS-02', jsonb_array_length(public.get_storefront()->'testimonials') = 1, 'section shows at most testi_limit');
update public.shop_settings set testi_enabled = false where id = 1;
select t.ok('TS-02', jsonb_array_length(public.get_storefront()->'testimonials') = 0
                     and not (public.get_storefront()->'testi'->>'enabled')::boolean, 'section switched off: nothing shown');

-- ---------------------------------------------------------------- PK-08 delete
begin;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
set local role authenticated;
select t.ok('PK-08', public.admin_delete_bundle(t.v('paket')::bigint), 'admin deletes the paket');
commit;
select t.ok('PK-08', (select count(*) from public.order_items oi join public.orders o on o.id = oi.order_id
                       where o.order_number = t.v('order') and oi.product_name = 'Paket Mager' and oi.line_total = 30000) = 1,
            'past order keeps the paket name and price');
select t.ok('PK-08', not exists (select 1 from public.bundle_items where bundle_id = t.v('paket')::bigint), 'its items are gone');

-- ---------------------------------------------------------------- report
\o
select id, case when ok then 'PASS' else 'FAIL' end as result, name, case when ok then '' else info end as info from t.results order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.results;
do $$ begin
  if exists (select 1 from t.results where not ok) then raise exception 'SOME TESTS FAILED'; end if;
end $$;
