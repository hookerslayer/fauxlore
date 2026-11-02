do $migration$
declare fn text; old_text text; new_text text;
begin
 fn:=pg_get_functiondef('fauxlore.wall_api(text,jsonb)'::regprocedure);
 old_text:=$old$  elsif action='verdict' then
    if actor.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;$old$;
 new_text:=$new$  elsif action='verdict' then
    if actor.role<>'admin' and (not fauxlore.judge_can_review(actor.id,nullif(payload->>'state_id','')::integer) or not exists(select 1 from fauxlore.wall_posts p join fauxlore.judge_assignments j on j.player_id=p.account_id where p.id=nullif(payload->>'post_id','')::bigint and j.judge_id=actor.id and p.account_id<>actor.id)) then raise sqlstate '42501' using message='Нет доступа к вердикту'; end if;$new$;
 if position(old_text in fn)=0 then raise exception 'wall verdict hook missing'; end if; execute replace(fn,old_text,new_text);
 fn:=pg_get_functiondef('fauxlore.wall_verdict_many(jsonb)'::regprocedure);
 old_text:=$old$  if actor.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;$old$;
 new_text:=$new$  if actor.role<>'admin' and not exists(select 1 from fauxlore.wall_posts p join fauxlore.judge_assignments j on j.player_id=p.account_id where p.id=nullif(payload->>'post_id','')::bigint and j.judge_id=actor.id and p.account_id<>actor.id) then raise sqlstate '42501' using message='Нет доступа к вердикту'; end if;$new$;
 if position(old_text in fn)=0 then raise exception 'verdict role hook missing'; end if; fn:=replace(fn,old_text,new_text);
 old_text:=$old$  if cardinality(target_ids)<>jsonb_array_length(payload->'state_ids') then$old$;
 new_text:=$new$  if actor.role<>'admin' and exists(select 1 from unnest(target_ids) x where not fauxlore.judge_can_review(actor.id,x)) then raise sqlstate '42501' using message='Нет доступа к государству'; end if;
  if cardinality(target_ids)<>jsonb_array_length(payload->'state_ids') then$new$;
 if position(old_text in fn)=0 then raise exception 'verdict states hook missing'; end if; execute replace(fn,old_text,new_text);
end $migration$;
notify pgrst,'reload schema';
