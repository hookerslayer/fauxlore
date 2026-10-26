do $migration$
declare definition text; marker text;
begin
 definition:=pg_get_functiondef('public.garrison_api(text,integer,integer,jsonb)'::regprocedure);
 marker:='where p.kind=''land'' and (v.category_id=sid or (v.category_id is null and g.state_id=sid and g.fort_level>0))';
 if position(marker in definition)=0 then raise exception 'Garrison candidate marker missing'; end if;
 execute replace(definition,marker,
   'where p.kind=''land'' and (v.category_id=sid or (v.category_id is null and
      ((g.state_id=sid and g.fort_level>0) or exists(select 1 from fauxlore.map_adjacency a
       join lateral jsonb_array_elements_text(a.neighbors->p.id::text) n(value) on true
       join fauxlore.province_values ownv on ownv.province_id=n.value::integer and ownv.layer=''states'' and ownv.category_id=sid
       where a.singleton))))');
end $migration$;
