-- =====================================================================
-- Migration 010: notification center + more order statuses
-- Safe to run on the live database (and safe to run twice).
--
-- * orders.status gets 'ready' (siap diantar) and 'shipping' (sedang diantar).
-- * notifications: one row per customer per event. Customers only see their own.
--     kind 'product'  a new product appears in the shop       -> every registered user
--     kind 'promo'    a new promotion starts (if announced)    -> every registered user
--     kind 'order'    their order changes status               -> only the order's owner
--   event_key is unique per user, so a retried webhook or a double click never
--   creates the same notification twice.
-- * notification_events: one row per broadcast (product / promo) already sent.
-- * Everything is created by database triggers, so it works no matter who makes the
--   change (admin page, Midtrans webhook, SQL editor). Customers can't create any.
-- =====================================================================
begin;

-- ---------------------------------------------------------------- order statuses
alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check
  check (status in ('pending','paid','processing','ready','shipping','completed','cancelled','expired','failed'));

create or replace function public.admin_set_order_status(p_order_id uuid, p_status text)
returns text language plpgsql security definer set search_path = public as $$
declare v_order public.orders;
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;

  if p_status = 'cancelled' and v_order.status = 'pending' then
    return public.release_order(v_order.order_number, 'cancelled');
  elsif p_status = 'cancelled' and v_order.status in ('paid','processing','ready','shipping') then
    -- paid order cancelled: refund is done manually in Midtrans; stock is NOT returned automatically
    update public.orders set status = 'cancelled' where id = p_order_id;
  elsif p_status = 'processing' and v_order.status = 'paid'
     or p_status = 'ready'      and v_order.status in ('paid','processing')
     or p_status = 'shipping'   and v_order.status in ('paid','processing','ready')
     or p_status = 'completed'  and v_order.status in ('paid','processing','ready','shipping') then
    update public.orders set status = p_status where id = p_order_id;
  else
    raise exception 'INVALID_TRANSITION:%->%', v_order.status, p_status;
  end if;
  return p_status;
end $$;

-- customer list: ready / shipping orders count as paid
do $$
declare v_src text;
begin
  v_src := pg_get_functiondef('public.admin_list_customers(text)'::regprocedure);
  if position('''ready''' in v_src) = 0 then
    v_src := replace(v_src, '(''paid'',''processing'',''completed'')', '(''paid'',''processing'',''ready'',''shipping'',''completed'')');
    execute v_src;
  end if;
end $$;

-- ---------------------------------------------------------------- promotions: announce or keep private
alter table public.promotions add column if not exists announce boolean not null default true;

-- ---------------------------------------------------------------- tables
create table if not exists public.notification_events (
  event_key   text primary key,             -- 'product:12', 'promo:5'
  kind        text not null,
  ref_id      text,
  recipients  integer not null default 0,
  created_at  timestamptz not null default now()
);

create table if not exists public.notifications (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  kind        text not null check (kind in ('product','promo','order')),
  title       text not null,
  body        text,
  link        text,                          -- '#produk/12', '#promo/5', '#pesanan/CN-...'
  ref_id      text,                          -- product id, promotion id or order number
  event_key   text not null,
  created_at  timestamptz not null default now(),
  read_at     timestamptz,
  unique (user_id, event_key)
);
create index if not exists notifications_user_idx on public.notifications (user_id, created_at desc);
create index if not exists notifications_unread_idx on public.notifications (user_id) where read_at is null;

alter table public.notifications enable row level security;
alter table public.notification_events enable row level security;
drop policy if exists notifications_own on public.notifications;
create policy notifications_own on public.notifications for select to authenticated using (user_id = auth.uid());
drop policy if exists notification_events_admin on public.notification_events;
create policy notification_events_admin on public.notification_events for select to authenticated using (public.is_admin());
revoke insert, update, delete on public.notifications, public.notification_events from anon, authenticated;

-- products and promos that exist before this migration are not "new"
insert into public.notification_events (event_key, kind, ref_id)
  select 'product:' || id, 'product', id::text from public.products
  on conflict do nothing;
insert into public.notification_events (event_key, kind, ref_id)
  select 'promo:' || id, 'promo', id::text from public.promotions
  on conflict do nothing;

-- ---------------------------------------------------------------- broadcasts
-- Send one broadcast to every registered user, once per event_key
create or replace function public.notify_all(p_event text, p_kind text, p_ref text, p_title text, p_body text, p_link text)
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  insert into public.notification_events (event_key, kind, ref_id) values (p_event, p_kind, p_ref)
    on conflict (event_key) do nothing;
  if not found then return 0; end if;          -- already announced
  insert into public.notifications (user_id, kind, title, body, link, ref_id, event_key)
    select p.id, p_kind, p_title, p_body, p_link, p_ref, p_event
      from public.profiles p join auth.users u on u.id = p.id
    on conflict (user_id, event_key) do nothing;
  get diagnostics v_n = row_count;
  update public.notification_events set recipients = v_n where event_key = p_event;
  return v_n;
end $$;

-- Is this promo live for customers right now (and allowed to be announced)?
create or replace function public.promo_is_live(pr public.promotions)
returns boolean language sql stable as $$
  select pr.is_active and pr.announce
     and (pr.starts_at is null or pr.starts_at <= now())
     and (pr.ends_at is null or pr.ends_at > now())
     and (pr.usage_limit is null or pr.used_count < pr.usage_limit);
$$;

create or replace function public.announce_product(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare p public.products;
begin
  if exists (select 1 from public.notification_events where event_key = 'product:' || p_id) then return; end if;
  if not public.product_on_sale(p_id) then return; end if;   -- wait until it is visible in the shop
  select * into p from public.products where id = p_id;
  perform public.notify_all('product:' || p.id, 'product', p.id::text,
    'Menu baru: ' || p.name,
    coalesce(nullif(p.subtitle, ''), 'Sekarang sudah bisa dipesan di CamilaNika.'),
    '#produk/' || p.id);
end $$;

create or replace function public.announce_promo(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare pr public.promotions; v_what text;
begin
  if exists (select 1 from public.notification_events where event_key = 'promo:' || p_id) then return; end if;
  select * into pr from public.promotions where id = p_id;
  if not found or not public.promo_is_live(pr) then return; end if;  -- future promos are sent when they start
  v_what := case pr.discount_type
              when 'percent' then 'Diskon ' || pr.value || '%'
              when 'fixed' then 'Potongan Rp' || replace(to_char(pr.value, 'FM999,999,999'), ',', '.')
              else coalesce(pr.gift_text, 'Hadiah gratis') end
         || case when pr.min_spend > 0 then ' untuk belanja minimal Rp' || replace(to_char(pr.min_spend, 'FM999,999,999'), ',', '.') else '' end
         || case when pr.code is not null then '. Pakai kode ' || pr.code else '' end
         || case when pr.ends_at is not null then ', sampai ' || to_char(pr.ends_at at time zone 'Asia/Jakarta', 'DD/MM HH24:MI') else '' end
         || '.';
  perform public.notify_all('promo:' || pr.id, 'promo', pr.id::text, 'Promo baru: ' || pr.name,
    coalesce(nullif(pr.description, '') || ' ', '') || v_what, '#promo/' || pr.id);
end $$;

-- Catch broadcasts that became due without an edit (a promo whose start time passed,
-- a menu section switched on). Called when customers load their notifications.
create or replace function public.announce_due()
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select pr.id from public.promotions pr
            where public.promo_is_live(pr)
              and not exists (select 1 from public.notification_events e where e.event_key = 'promo:' || pr.id) loop
    perform public.announce_promo(r.id);
  end loop;
  for r in select p.id from public.products p
            where not exists (select 1 from public.notification_events e where e.event_key = 'product:' || p.id)
              and public.product_on_sale(p.id) loop
    perform public.announce_product(r.id);
  end loop;
end $$;

create or replace function public.trg_announce_product()
returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.announce_product(new.id); return null; end $$;
drop trigger if exists trg_products_announce on public.products;
create trigger trg_products_announce after insert or update of is_active, section_id on public.products
  for each row execute function public.trg_announce_product();

create or replace function public.trg_announce_promo()
returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.announce_promo(new.id); return null; end $$;
drop trigger if exists trg_promotions_announce on public.promotions;
create trigger trg_promotions_announce after insert or update on public.promotions
  for each row execute function public.trg_announce_promo();

-- ---------------------------------------------------------------- order updates (owner only)
create or replace function public.trg_notify_order()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_title text; v_body text; n text := new.order_number;
begin
  if new.user_id is null then return null; end if;                       -- guest order: nobody to notify
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then return null; end if;
  select t, b into v_title, v_body from (values
    ('pending',    'Pesanan dibuat',            'Pesanan ' || n || ' menunggu pembayaran. Selesaikan dalam 30 menit.'),
    ('paid',       'Pembayaran diterima',       'Pesanan ' || n || ' sudah dibayar. Kami segera menyiapkannya.'),
    ('processing', 'Pesanan sedang disiapkan',  'Pesanan ' || n || ' sedang kami siapkan.'),
    ('ready',      'Pesanan siap diantar',      'Pesanan ' || n || ' sudah siap dan menunggu kurir.'),
    ('shipping',   'Pesanan sedang diantar',    'Pesanan ' || n || ' sedang dalam perjalanan ke alamat kamu.'),
    ('completed',  'Pesanan selesai',           'Pesanan ' || n || ' sudah selesai. Terima kasih, selamat menikmati!'),
    ('cancelled',  'Pesanan dibatalkan',        'Pesanan ' || n || ' dibatalkan. Chat kami kalau ada pertanyaan.'),
    ('failed',     'Pembayaran gagal',          'Pembayaran pesanan ' || n || ' gagal. Silakan pesan lagi.'),
    ('expired',    'Waktu pembayaran habis',    'Pesanan ' || n || ' batal karena belum dibayar dalam 30 menit.')
  ) s(st, t, b) where s.st = new.status;
  if v_title is null then return null; end if;
  insert into public.notifications (user_id, kind, title, body, link, ref_id, event_key)
    values (new.user_id, 'order', v_title, v_body, '#pesanan/' || n, n, 'order:' || new.id || ':' || new.status)
    on conflict (user_id, event_key) do nothing;
  return null;
end $$;
drop trigger if exists trg_orders_notify on public.orders;
create trigger trg_orders_notify after insert or update of status on public.orders
  for each row execute function public.trg_notify_order();

-- ---------------------------------------------------------------- customer API
-- Latest notifications + unread count. 'available' says whether the linked product,
-- promo or order can still be opened (deleted product, ended promo, removed order).
create or replace function public.my_notifications(p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'NOT_LOGGED_IN'; end if;
  perform public.announce_due();
  return jsonb_build_object(
    'unread', (select count(*) from public.notifications where user_id = v_uid and read_at is null),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', n.id, 'kind', n.kind, 'title', n.title, 'body', n.body, 'link', n.link, 'ref_id', n.ref_id,
        'created_at', n.created_at, 'read', n.read_at is not null,
        'available', case n.kind
           when 'product' then public.product_on_sale(n.ref_id::bigint)
           when 'promo' then exists (select 1 from public.promotions pr where pr.id = n.ref_id::bigint and public.promo_is_live(pr))
           else exists (select 1 from public.orders o where o.order_number = n.ref_id and o.user_id = v_uid) end)
        order by n.created_at desc, n.id desc)
      from (select * from public.notifications where user_id = v_uid
             order by created_at desc, id desc limit greatest(1, least(p_limit, 200))) n), '[]'::jsonb));
end $$;

create or replace function public.unread_notifications()
returns integer language sql stable security definer set search_path = public as $$
  select count(*)::int from public.notifications where user_id = auth.uid() and read_at is null;
$$;

-- Mark some (or, with no ids, all) of my notifications as read
create or replace function public.mark_notifications_read(p_ids bigint[] default null)
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  if auth.uid() is null then raise exception 'NOT_LOGGED_IN'; end if;
  update public.notifications set read_at = now()
   where user_id = auth.uid() and read_at is null and (p_ids is null or id = any(p_ids));
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Public details of an announced promo (for the promo page a notification opens)
create or replace function public.promo_details(p_id bigint)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', pr.id, 'name', pr.name, 'description', pr.description,
    'discount_type', pr.discount_type, 'value', pr.value, 'gift_text', pr.gift_text,
    'min_spend', pr.min_spend, 'max_discount', pr.max_discount, 'code', pr.code,
    'starts_at', pr.starts_at, 'ends_at', pr.ends_at, 'live', public.promo_is_live(pr))
  from public.promotions pr where pr.id = p_id and pr.announce;
$$;

revoke execute on function public.notify_all(text, text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.announce_product(bigint) from public, anon, authenticated;
revoke execute on function public.announce_promo(bigint) from public, anon, authenticated;
revoke execute on function public.announce_due() from public, anon, authenticated;
revoke execute on function public.my_notifications(integer) from public, anon;
revoke execute on function public.unread_notifications() from public, anon;
revoke execute on function public.mark_notifications_read(bigint[]) from public, anon;
grant execute on function public.my_notifications(integer) to authenticated;
grant execute on function public.unread_notifications() to authenticated;
grant execute on function public.mark_notifications_read(bigint[]) to authenticated;
grant execute on function public.promo_details(bigint) to anon, authenticated;

commit;
