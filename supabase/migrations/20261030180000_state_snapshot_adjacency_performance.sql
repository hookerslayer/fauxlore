-- Extract the large adjacency document once per snapshot instead of once per
-- province. Preserve the directed neighbor relation used by garrisons.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
  old_fragment:='''neighbors'',coalesce((select g.neighbors->p.id::text from fauxlore.map_adjacency g where g.singleton),''[]''::jsonb)';
  new_fragment:='''neighbors'',coalesce(adj.neighbors,''[]''::jsonb)';
  if position(old_fragment in fn)=0 then raise exception 'Military neighbor expression changed'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:='from fauxlore.provinces p left join fauxlore.province_values pv on pv.province_id=p.id and pv.layer=''states'''||chr(10)||
    '      where pv.category_id=sid or p.kind=''sea'' or (is_admin and p.kind=''land'')';
  new_fragment:='from fauxlore.provinces p left join fauxlore.province_values pv on pv.province_id=p.id and pv.layer=''states'''||chr(10)||
    '      left join (select e.key::integer id,e.value neighbors from fauxlore.map_adjacency g cross join lateral jsonb_each(g.neighbors) e where g.singleton) adj on adj.id=p.id'||chr(10)||
    '      where pv.category_id=sid or p.kind=''sea'' or (is_admin and p.kind=''land'')';
  if position(old_fragment in fn)=0 then raise exception 'Military province source changed'; end if;
  execute replace(fn,old_fragment,new_fragment);

  fn:=pg_get_functiondef('public.garrison_api(text,integer,integer,jsonb)'::regprocedure);
  old_fragment:='exists(select 1 from fauxlore.map_adjacency a'||chr(10)||
    '       join lateral jsonb_array_elements_text(a.neighbors->p.id::text) n(value) on true'||chr(10)||
    '       join fauxlore.province_values ownv on ownv.province_id=n.value::integer and ownv.layer=''states'' and ownv.category_id=sid'||chr(10)||
    '       where a.singleton)';
  new_fragment:='p.id in (select e.key::integer from fauxlore.map_adjacency a'||chr(10)||
    '       cross join lateral jsonb_each(a.neighbors) e(key,value)'||chr(10)||
    '       cross join lateral jsonb_array_elements_text(e.value) n(value)'||chr(10)||
    '       join fauxlore.province_values ownv on ownv.province_id=n.value::integer and ownv.layer=''states'' and ownv.category_id=sid'||chr(10)||
    '       where a.singleton)';
  if position(old_fragment in fn)=0 then raise exception 'Garrison neighbor predicate changed'; end if;
  execute replace(fn,old_fragment,new_fragment);
end
$migration$;
notify pgrst,'reload schema';
