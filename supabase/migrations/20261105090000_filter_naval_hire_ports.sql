-- Only expose ports that pass the same ownership check as naval recruitment.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
  old_fragment:=$old$'port',exists(select 1 from fauxlore.map_markers m where m.province_id=p.id and m.type='port')$old$;
  new_fragment:=$new$'port',exists(select 1 from fauxlore.map_markers m join fauxlore.map_adjacency a on a.singleton join lateral jsonb_array_elements_text(a.neighbors->m.province_id::text) n(value) on true join fauxlore.province_values v on v.province_id=n.value::integer and v.layer='states' and v.category_id=sid where m.province_id=p.id and m.type='port')$new$;
  if position(old_fragment in fn)=0 then raise exception 'Military snapshot port expression changed'; end if;
  execute replace(fn,old_fragment,new_fragment);
end
$migration$;
