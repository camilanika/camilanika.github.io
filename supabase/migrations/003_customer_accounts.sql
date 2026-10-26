-- =====================================================================
-- Migration 003: customer accounts in the admin page
-- Safe to run on the live database. Run once in Supabase → SQL Editor.
--
-- Adds
--   profiles.email                 copy of the login email (kept in sync)
--   admin_list_customers(search)   accounts with order count, total spent, last order
--   admin_set_role(user, role)     make someone admin / customer
-- =====================================================================
begin;

-- 1. Email on the profile (admins can't read auth.users directly)
alter table public.profiles add column if not exists email text;
update public.profiles p set email = u.email from auth.users u where u.id = p.id and p.email is distinct from u.email;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, phone, email)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
          new.raw_user_meta_data->>'phone',
          new.email)
  on conflict (id) do update set email = excluded.email;
  return new;
end $$;

create or replace function public.handle_user_email_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.profiles set email = new.email where id = new.id;
  return new;
end $$;

drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed after update of email on auth.users
  for each row when (old.email is distinct from new.email)
  execute function public.handle_user_email_change();

-- 2. Customer list for admins
create or replace function public.admin_list_customers(p_search text default null)
returns table (
  id uuid, email text, full_name text, phone text, address text, role text,
  created_at timestamptz, confirmed boolean, last_sign_in_at timestamptz,
  orders_count bigint, paid_count bigint, total_spent bigint, last_order_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  return query
  select p.id, coalesce(p.email, u.email)::text, p.full_name, p.phone, p.address, p.role,
         p.created_at, (u.email_confirmed_at is not null), u.last_sign_in_at,
         count(o.id), count(o.id) filter (where o.status in ('paid','processing','completed')),
         coalesce(sum(o.total) filter (where o.status in ('paid','processing','completed')), 0)::bigint,
         max(o.created_at)
    from public.profiles p
    join auth.users u on u.id = p.id
    left join public.orders o on o.user_id = p.id
   where p_search is null or p_search = ''
      or coalesce(p.email, u.email) ilike '%' || p_search || '%'
      or p.full_name ilike '%' || p_search || '%'
      or p.phone ilike '%' || p_search || '%'
   group by p.id, u.email, u.email_confirmed_at, u.last_sign_in_at
   order by (p.role = 'admin') desc, max(o.created_at) desc nulls last, p.created_at desc
   limit 500;
end $$;

-- 3. Change someone's role (you can't remove your own admin access)
create or replace function public.admin_set_role(p_user_id uuid, p_role text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  if p_role not in ('customer','admin') then raise exception 'INVALID_ROLE'; end if;
  if p_user_id = auth.uid() and p_role <> 'admin' then raise exception 'CANNOT_REMOVE_OWN_ADMIN'; end if;
  update public.profiles set role = p_role where id = p_user_id;
  if not found then raise exception 'USER_NOT_FOUND'; end if;
  return p_role;
end $$;

revoke execute on function public.admin_list_customers(text) from public, anon;
revoke execute on function public.admin_set_role(uuid, text) from public, anon;
revoke execute on function public.handle_user_email_change() from public, anon, authenticated;
grant execute on function public.admin_list_customers(text) to authenticated;
grant execute on function public.admin_set_role(uuid, text) to authenticated;

commit;
