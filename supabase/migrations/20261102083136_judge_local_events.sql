do $migration$
declare fn text; old_text text; new_text text;
begin
 fn:=pg_get_functiondef('public.local_events_api(text,jsonb)'::regprocedure);
 old_text:=$old$  if coalesce(actor.role,'')<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;$old$;
 new_text:=$new$  if coalesce(actor.role,'')<>'admin' then
    if not exists(select 1 from fauxlore.judge_assignments where judge_id=actor.id) then raise sqlstate '42501' using message='Нет прав судьи'; end if;
    if action='create' and not exists(select 1 from fauxlore.province_values o where o.layer='states' and o.province_id=nullif(payload->>'province_id','')::integer and fauxlore.judge_can_review(actor.id,o.category_id)) then raise sqlstate '42501' using message='Нет доступа к провинции'; end if;
    if action='end' and not exists(select 1 from fauxlore.local_events e join fauxlore.province_values o on o.province_id=e.province_id and o.layer='states' where e.id=nullif(payload->>'event_id','')::bigint and fauxlore.judge_can_review(actor.id,o.category_id)) then raise sqlstate '42501' using message='Нет доступа к событию'; end if;
  end if;$new$;
 if position(old_text in fn)=0 then raise exception 'event authorization hook missing'; end if; fn:=replace(fn,old_text,new_text);
 old_text:=$old$from fauxlore.provinces p where p.kind='land'),'[]'::jsonb)$old$;
 new_text:=$new$from fauxlore.provinces p where p.kind='land' and (actor.role='admin' or exists(select 1 from fauxlore.province_values o where o.layer='states' and o.province_id=p.id and fauxlore.judge_can_review(actor.id,o.category_id)))),'[]'::jsonb)$new$;
 if position(old_text in fn)=0 then raise exception 'event province filter hook missing'; end if; fn:=replace(fn,old_text,new_text);
 execute fn;
end $migration$;
notify pgrst,'reload schema';
