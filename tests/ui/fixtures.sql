-- Data for the UI tests: an admin, a customer, and three online orders completed "now" (this month).
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@test.local'),
  ('00000000-0000-0000-0000-00000000000c', 'customer@test.local');
update public.profiles set role = 'admin', full_name = 'Admin Tes' where id = '00000000-0000-0000-0000-00000000000a';
update public.inventory set unlimited = true;

do $$
declare o jsonb; spec record;
begin
  for spec in select * from (values
      ('[{"variant_id":1,"quantity":2}]', 'production', 'Budi',  false),   -- real   26.000 (2x Americano S)
      ('[{"variant_id":34,"quantity":1}]', 'production', 'Sari', false),   -- real   18.500 (1x Matcha Latte S)
      ('[{"variant_id":25,"quantity":3}]', 'sandbox', 'TES SISTEM', true)  -- mock   49.500, flagged for review
    ) v(items, env, name, review) loop
    o := public.create_order(null, spec.items::jsonb, null, spec.name, '081234567890');
    perform public.tag_order_payment_env(o->>'order_number', spec.env);
    perform public.mark_order_paid(o->>'order_number', 'ref', 'qris');
    perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
    perform public.admin_set_order_status((select id from public.orders where order_number = o->>'order_number'), 'completed');
    perform set_config('request.jwt.claim.sub', '', false);
    if spec.review then
      update public.orders set classification_source = 'migration', classification_review = true,
             classification_note = 'Dibuat saat pembayaran Midtrans masih Sandbox (tes).'
       where order_number = o->>'order_number';
    end if;
  end loop;
  -- one order still being processed: must not appear anywhere in Cashflow
  o := public.create_order(null, '[{"variant_id":1,"quantity":9}]'::jsonb, null, 'Belum selesai', '081234567890');
  perform public.tag_order_payment_env(o->>'order_number', 'production');
  perform public.mark_order_paid(o->>'order_number', 'ref', 'qris');
end $$;
