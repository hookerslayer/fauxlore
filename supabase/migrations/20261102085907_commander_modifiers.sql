insert into fauxlore.permanent_modifier_definitions(source_kind,source_key,modifier_key,effect,value,unit,scope,condition_text) values
 ('constructor','Назначение','leader_limit_flat','Лимит полководцев',0,'ед.','Государство',''),
 ('constructor','Назначение','leader_prestige_cost_flat','Стоимость полководца',0,'ОП','Государство','');
create function fauxlore.leader_prestige_cost(target_state integer) returns integer language sql stable security definer set search_path='' as $$
 select greatest(0,10+floor(fauxlore.state_permanent_modifier_total(target_state,array['leader_prestige_cost_flat'],null,null)))::integer
$$;
revoke all on function fauxlore.leader_prestige_cost(integer) from public,anon,authenticated;
do $migration$
declare fn text; marker text; replacement text; amount integer;
begin
 fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
 marker:=$old$then 1 else 0 end)$old$;
 amount:=(length(fn)-length(replace(fn,marker,'')))/length(marker);
 if amount<>3 then raise exception 'commander limit snapshot hook count %',amount; end if;
 fn:=replace(fn,marker,$new$then 1 else 0 end+floor(fauxlore.state_permanent_modifier_total(sid,array['leader_limit_flat'],null,null))::integer)$new$);
 marker:=$old$'leader_hire_cost',floor($old$;
 if position(marker in fn)=0 then raise exception 'commander cost snapshot hook missing'; end if;fn:=replace(fn,marker,$new$'leader_prestige_cost',fauxlore.leader_prestige_cost(sid),'leader_hire_cost',floor($new$);
 execute fn;
 fn:=pg_get_functiondef('fauxlore.military_actions_extra(text,integer,jsonb)'::regprocedure);
 marker:=$old$then 1 else 0 end) into limit_value;$old$;
 if position(marker in fn)=0 then raise exception 'commander limit action hook missing'; end if;fn:=replace(fn,marker,$new$then 1 else 0 end+floor(fauxlore.state_permanent_modifier_total(sid,array['leader_limit_flat'],null,null))::integer) into limit_value;$new$);
 marker:=$old$if prestige_value<10 or tradition_value<5 then raise sqlstate '22023' using message='Нужно 10 ОП и 5% традиций'; end if;$old$;
 if position(marker in fn)=0 then raise exception 'commander prestige check hook missing'; end if;fn:=replace(fn,marker,$new$if prestige_value<fauxlore.leader_prestige_cost(sid) or tradition_value<5 then raise sqlstate '22023' using message='Недостаточно Престижа или традиций для найма'; end if;$new$);
 marker:=$old$prestige=prestige-10,treasury=treasury-price$old$;
 if position(marker in fn)=0 then raise exception 'commander prestige charge hook missing'; end if;fn:=replace(fn,marker,$new$prestige=prestige-fauxlore.leader_prestige_cost(sid),treasury=treasury-price$new$);
 execute fn;
end $migration$;
notify pgrst,'reload schema';
