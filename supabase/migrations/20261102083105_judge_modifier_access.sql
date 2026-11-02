do $migration$
declare fn text; old_text text; new_text text;
begin
 fn:=pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure);
 old_text:=$old$  if coalesce(actor.role,'')<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;$old$;
 new_text:=$new$  if coalesce(actor.role,'')<>'admin' then
    if not exists(select 1 from fauxlore.judge_assignments where judge_id=actor.id) then raise sqlstate '42501' using message='Нет прав судьи'; end if;
    if action in ('assign','resource_assign') and not fauxlore.judge_can_review(actor.id,nullif(payload->>'state_id','')::integer) then raise sqlstate '42501' using message='Нет доступа к государству'; end if;
    if action='delete' and not exists(select 1 from fauxlore.admin_modifier_assignments a where a.id=(payload->>'modifier_id')::bigint and fauxlore.judge_can_review(actor.id,a.state_id)) then raise sqlstate '42501' using message='Нет доступа к модификатору'; end if;
  end if;$new$;
 if position(old_text in fn)=0 then raise exception 'modifier authorization hook missing'; end if;
 fn:=replace(fn,old_text,new_text);
 old_text:=$old$from fauxlore.map_categories c where c.layer='states'),'[]'::jsonb)$old$;
 new_text:=$new$from fauxlore.map_categories c where c.layer='states' and (actor.role='admin' or fauxlore.judge_can_review(actor.id,c.id))),'[]'::jsonb)$new$;
 if position(old_text in fn)=0 then raise exception 'state filter hook missing'; end if; fn:=replace(fn,old_text,new_text);
 old_text:=$old$where owner.layer='states' and p.kind='land'),'[]'::jsonb)$old$;
 new_text:=$new$where owner.layer='states' and p.kind='land' and (actor.role='admin' or fauxlore.judge_can_review(actor.id,owner.category_id))),'[]'::jsonb)$new$;
 if position(old_text in fn)=0 then raise exception 'province filter hook missing'; end if; fn:=replace(fn,old_text,new_text);
 old_text:=$old$left join fauxlore.provinces p on p.id=a.province_id),'[]'::jsonb)$old$;
 new_text:=$new$left join fauxlore.provinces p on p.id=a.province_id where actor.role='admin' or fauxlore.judge_can_review(actor.id,a.state_id)),'[]'::jsonb)$new$;
 if position(old_text in fn)=0 then raise exception 'assigned filter hook missing'; end if; fn:=replace(fn,old_text,new_text);
 execute fn;
end $migration$;
notify pgrst,'reload schema';
