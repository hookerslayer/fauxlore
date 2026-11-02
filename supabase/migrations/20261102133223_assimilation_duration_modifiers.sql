insert into fauxlore.permanent_modifier_definitions(source_kind,source_key,modifier_key,effect,value,unit,scope,condition_text) values
 ('constructor','Назначение','race_assimilation_turns','Ассимиляция расы',0,'ход','Государство',''),
 ('constructor','Назначение','religion_assimilation_turns','Ассимиляция религии',0,'ход','Государство','');
alter table fauxlore.provinces add column race_assimilation_modifier_applied integer not null default 0,
 add column religion_assimilation_modifier_applied integer not null default 0;
do $migration$
declare fn text; marker text;
begin
 fn:=pg_get_functiondef('fauxlore.process_province_assimilation()'::regprocedure);
 marker:=$old$status_value text; remaining integer; stored_target integer; changed integer:=0; touched boolean:=false;$old$;
 if position(marker in fn)=0 then raise exception 'assimilation declarations missing'; end if;
 fn:=replace(fn,marker,$new$status_value text; remaining integer; stored_target integer; changed integer:=0; touched boolean:=false; old_modifier integer; desired_modifier integer; adjusted_remaining integer;$new$);
 marker:=$old$p.religion_assimilation_turns,p.religion_assimilation_target_id$old$;
 if position(marker in fn)=0 then raise exception 'assimilation columns missing'; end if;
 fn:=replace(fn,marker,$new$p.religion_assimilation_turns,p.religion_assimilation_target_id,p.race_assimilation_modifier_applied,p.religion_assimilation_modifier_applied$new$);
 marker:=$old$remaining:=province_row.race_assimilation_turns;stored_target:=province_row.race_assimilation_target_id;$old$;
 if position(marker in fn)=0 then raise exception 'race timer missing'; end if;
 fn:=replace(fn,marker,$new$remaining:=province_row.race_assimilation_turns;stored_target:=province_row.race_assimilation_target_id;old_modifier:=province_row.race_assimilation_modifier_applied;$new$);
 marker:=$old$remaining:=province_row.religion_assimilation_turns;stored_target:=province_row.religion_assimilation_target_id;$old$;
 if position(marker in fn)=0 then raise exception 'religion timer missing'; end if;
 fn:=replace(fn,marker,$new$remaining:=province_row.religion_assimilation_turns;stored_target:=province_row.religion_assimilation_target_id;old_modifier:=province_row.religion_assimilation_modifier_applied;$new$);
 marker:=$old$remaining:=fauxlore.assimilation_duration(coalesce(status_value,'Невмешательство'));$old$;
 if position(marker in fn)=0 then raise exception 'assimilation initialization missing'; end if;
 fn:=replace(fn,marker,$new$remaining:=fauxlore.assimilation_duration(coalesce(status_value,'Невмешательство'));old_modifier:=0;$new$);
 marker:=$old$      if remaining<=1 then$old$;
 if position(marker in fn)=0 then raise exception 'assimilation calculation missing'; end if;
 fn:=replace(fn,marker,$new$      desired_modifier:=round(fauxlore.state_permanent_modifier_total(province_row.state_id,array[case group_kind when 'race' then 'race_assimilation_turns' else 'religion_assimilation_turns' end],province_row.id,null))::integer;
      adjusted_remaining:=greatest(1,least(300,remaining+desired_modifier-old_modifier));
      old_modifier:=old_modifier+adjusted_remaining-remaining;remaining:=adjusted_remaining;
      if group_kind='race' then update fauxlore.provinces set race_assimilation_modifier_applied=old_modifier where id=province_row.id;
      else update fauxlore.provinces set religion_assimilation_modifier_applied=old_modifier where id=province_row.id; end if;
      if remaining<=1 then$new$);
 execute fn;
 fn:=pg_get_functiondef('fauxlore.set_province_assimilation(integer,jsonb)'::regprocedure);
 marker:=$old$race_assimilation_turns=nullif(race_turns,0),race_assimilation_target_id=case when race_turns>0 then official_race else null end,$old$;
 if position(marker in fn)=0 then raise exception 'manual race timer missing';end if;
 fn:=replace(fn,marker,$new$race_assimilation_turns=nullif(race_turns,0),race_assimilation_target_id=case when race_turns>0 then official_race else null end,race_assimilation_modifier_applied=0,$new$);
 marker:=$old$religion_assimilation_turns=nullif(religion_turns,0),religion_assimilation_target_id=case when religion_turns>0 then official_religion else null end$old$;
 if position(marker in fn)=0 then raise exception 'manual religion timer missing';end if;
 fn:=replace(fn,marker,$new$religion_assimilation_turns=nullif(religion_turns,0),religion_assimilation_target_id=case when religion_turns>0 then official_religion else null end,religion_assimilation_modifier_applied=0$new$);execute fn;
 fn:=pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure);
 marker:=$old$'control_modifier_pp'$old$;
 if position(marker in fn)=0 then raise exception 'modifier scope whitelist missing';end if;
 fn:=replace(fn,marker,$new$'race_assimilation_turns','religion_assimilation_turns','control_modifier_pp'$new$);execute fn;
end $migration$;
do $migration$
declare fn text; marker text; name text;
begin
 foreach name in array array['fauxlore.capture_test_turn_assimilation()','fauxlore.turn_snapshot_payload()'] loop
  fn:=pg_get_functiondef(name::regprocedure);
  marker:=$old$'religion_assimilation_target_id',religion_assimilation_target_id$old$;
  if position(marker in fn)=0 then raise exception 'assimilation snapshot hook missing: %',name; end if;
  fn:=replace(fn,marker,$new$'religion_assimilation_target_id',religion_assimilation_target_id,'race_assimilation_modifier_applied',race_assimilation_modifier_applied,'religion_assimilation_modifier_applied',religion_assimilation_modifier_applied$new$);execute fn;
 end loop;
 fn:=pg_get_functiondef('fauxlore.restore_test_turn_assimilation()'::regprocedure);
 marker:=$old$religion_assimilation_target_id=(saved->>'religion_assimilation_target_id')::integer$old$;
 if position(marker in fn)=0 then raise exception 'assimilation restore hook missing'; end if;
 fn:=replace(fn,marker,$new$religion_assimilation_target_id=(saved->>'religion_assimilation_target_id')::integer,race_assimilation_modifier_applied=coalesce((saved->>'race_assimilation_modifier_applied')::integer,0),religion_assimilation_modifier_applied=coalesce((saved->>'religion_assimilation_modifier_applied')::integer,0)$new$);execute fn;
end $migration$;
notify pgrst,'reload schema';
