create function fauxlore.sync_assimilation_modifiers(target_state integer) returns void
language plpgsql security definer set search_path='' as $$
declare p record; desired integer; adjusted integer; applied integer;
begin
 for p in select pr.id,pr.race_assimilation_turns,pr.race_assimilation_target_id,pr.race_assimilation_modifier_applied,
 pr.religion_assimilation_turns,pr.religion_assimilation_target_id,pr.religion_assimilation_modifier_applied
 from fauxlore.provinces pr join fauxlore.province_values owner on owner.province_id=pr.id and owner.layer='states' and owner.category_id=target_state
 where pr.kind='land' and (pr.race_assimilation_turns is not null or pr.religion_assimilation_turns is not null) order by pr.id for update of pr loop
  if p.race_assimilation_turns is not null and p.race_assimilation_target_id is not null then
   desired:=round(fauxlore.state_permanent_modifier_total(target_state,array['race_assimilation_turns'],p.id,null))::integer;
   adjusted:=greatest(1,least(300,p.race_assimilation_turns+desired-p.race_assimilation_modifier_applied));
   applied:=p.race_assimilation_modifier_applied+adjusted-p.race_assimilation_turns;
   if adjusted<>p.race_assimilation_turns or applied<>p.race_assimilation_modifier_applied then
    update fauxlore.provinces set race_assimilation_turns=adjusted,race_assimilation_modifier_applied=applied where id=p.id;end if;
  end if;
  if p.religion_assimilation_turns is not null and p.religion_assimilation_target_id is not null then
   desired:=round(fauxlore.state_permanent_modifier_total(target_state,array['religion_assimilation_turns'],p.id,null))::integer;
   adjusted:=greatest(1,least(300,p.religion_assimilation_turns+desired-p.religion_assimilation_modifier_applied));
   applied:=p.religion_assimilation_modifier_applied+adjusted-p.religion_assimilation_turns;
   if adjusted<>p.religion_assimilation_turns or applied<>p.religion_assimilation_modifier_applied then
    update fauxlore.provinces set religion_assimilation_turns=adjusted,religion_assimilation_modifier_applied=applied where id=p.id;end if;
  end if;
 end loop;
end $$;
revoke all on function fauxlore.sync_assimilation_modifiers(integer) from public,anon,authenticated;
do $migration$
declare fn text;marker text;
begin
 fn:=pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure);
 marker:=$old$declare actor fauxlore.accounts; state_key integer; province_key integer; definition_index integer; def record;$old$;
 if position(marker in fn)=0 then raise exception 'modifier declarations missing';end if;
 fn:=replace(fn,marker,$new$declare actor fauxlore.accounts; state_key integer; province_key integer; definition_index integer; def record; deleted_modifier text;$new$);
 marker:=$old$where id=assignment_result_id;$old$;
 if position(marker in fn)=0 then raise exception 'assignment update missing';end if;
 fn:=replace(fn,marker,marker||$new$
    if def.modifier_key in ('race_assimilation_turns','religion_assimilation_turns') then perform fauxlore.sync_assimilation_modifiers(state_key);end if;$new$);
 marker:=$old$delete from fauxlore.admin_modifier_assignments where id=(payload->>'modifier_id')::bigint;$old$;
 if position(marker in fn)=0 then raise exception 'assignment deletion missing';end if;
 fn:=replace(fn,marker,$new$delete from fauxlore.admin_modifier_assignments where id=(payload->>'modifier_id')::bigint returning state_id,modifier_key into state_key,deleted_modifier;$new$);
 marker:=$old$if not found then raise sqlstate 'P0002' using message='Назначение модификатора не найдено'; end if;$old$;
 if position(marker in fn)=0 then raise exception 'assignment delete guard missing';end if;
 fn:=replace(fn,marker,marker||$new$
    if deleted_modifier in ('race_assimilation_turns','religion_assimilation_turns') then perform fauxlore.sync_assimilation_modifiers(state_key);end if;$new$);execute fn;
end $migration$;
