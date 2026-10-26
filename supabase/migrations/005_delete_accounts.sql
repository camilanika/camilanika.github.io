-- =====================================================================
-- Migration 005: allow deleting customer accounts while keeping order history
-- Safe to run on the live database (and safe to run twice).
--
-- When an account is deleted, its orders stay (with the name/phone/address saved on
-- the order) but are no longer linked to an account, like a guest order.
-- =====================================================================
begin;

do $$
declare r record;
begin
  for r in
    select con.conname, rel.relname, att.attname
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
      join pg_namespace ns on ns.oid = rel.relnamespace
      join pg_attribute att on att.attrelid = con.conrelid and att.attnum = any (con.conkey)
     where con.contype = 'f' and ns.nspname = 'public'
       and con.confrelid = 'auth.users'::regclass
       and rel.relname in ('orders', 'stock_movements')
       and con.confdeltype <> 'n'   -- not already ON DELETE SET NULL
  loop
    execute format('alter table public.%I drop constraint %I', r.relname, r.conname);
    execute format('alter table public.%I add constraint %I foreign key (%I) references auth.users(id) on delete set null',
                   r.relname, r.conname, r.attname);
  end loop;
end $$;

commit;
