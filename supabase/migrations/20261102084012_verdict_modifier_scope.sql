do $migration$
declare fn text; marker text; replacement text;
begin
 fn:=pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure);

 -- Use a short unique prefix so existing snapshot fields keep their order.
 marker:=$old$      'provinces',coalesce((select jsonb_agg($old$;
 replacement:=$new$      'groups',coalesce((select jsonb_agg(jsonb_build_object('state_id',g.state_id,'layer',g.layer,'id',g.id,'name',g.name) order by g.name,g.id) from (select distinct o.category_id state_id,v.layer,v.category_id id,c.name from fauxlore.province_values o join fauxlore.province_values v on v.province_id=o.province_id and v.layer in ('races','religions') join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id where o.layer='states' and (actor.role='admin' or fauxlore.judge_can_review(actor.id,o.category_id))) g),'[]'::jsonb),
      'provinces',coalesce((select jsonb_agg($new$;
 if position(marker in fn)=0 then raise exception 'snapshot group hook missing'; end if;
 execute replace(fn,marker,replacement);
 fn:=pg_get_functiondef('fauxlore.wall_verdict_many(jsonb)'::regprocedure);
 marker:=$old$item||jsonb_build_object('state_id',sid,'target_kind','state','province_id',null)$old$;
 replacement:=$new$item||jsonb_build_object('state_id',sid,'target_kind',case when item->>'province_id' is null then 'state' else 'province' end)$new$;
 if position(marker in fn)=0 then raise exception 'verdict province hook missing'; end if;
 execute replace(fn,marker,replacement);
end $migration$;
notify pgrst,'reload schema';
