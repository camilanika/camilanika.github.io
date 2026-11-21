-- 025: the server also respects "sizes" on a free choice (the bottle -> cup switch is only for S).
-- A choice that does not apply to the ordered size is left out of the order line, so the drink
-- goes out in its normal bottle even if an old copy of the shop page still offered the cup.
do $$
declare
  v_src text;
  v_old text := 'for v_grp in select * from jsonb_array_elements(v_var.choices) loop';
  v_new text := 'for v_grp in select g.value from jsonb_array_elements(v_var.choices) g where not (g.value ? ''sizes'') or (g.value->''sizes'') ? coalesce((select pv.attrs->>''Ukuran'' from public.product_variants pv where pv.id = v_var.id), '''') loop';
begin
  v_src := pg_get_functiondef('public.quote_cart_v(jsonb, text, uuid)'::regprocedure);
  if position(v_new in v_src) > 0 then
    raise notice 'already patched';
  elsif position(v_old in v_src) = 0 then
    raise exception 'quote_cart_v: choice loop not found, patch not applied';
  else
    execute replace(v_src, v_old, v_new);
  end if;
end $$;

-- check: M with the cup choice -> no Kemasan on the line; S with the cup -> kept
select l->>'variant_name' as variant, l->'choices' as choices
from jsonb_array_elements((public.quote_cart(
  (select jsonb_agg(jsonb_build_object('variant_id', v.id, 'quantity', 1,
          'choices', jsonb_build_object('Kemasan', 'Cup 16 oz + Es Batu')))
     from public.product_variants v join public.products p on p.id = v.product_id
    where p.slug = 'matcha'), null))->'items') l;
