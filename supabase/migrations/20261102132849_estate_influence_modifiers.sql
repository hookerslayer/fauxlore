insert into fauxlore.permanent_modifier_definitions(source_kind,source_key,modifier_key,effect,value,unit,scope,condition_text) values
 ('constructor','Назначение','nobility_influence_pp','Влияние Знати',0,'п.п.','Государство',''),
 ('constructor','Назначение','clergy_influence_pp','Влияние Духовенства',0,'п.п.','Государство',''),
 ('constructor','Назначение','burgher_influence_pp','Влияние Горожан',0,'п.п.','Государство',''),
 ('constructor','Назначение','peasant_influence_pp','Влияние Крестьян',0,'п.п.','Государство','');
create function fauxlore.adjust_estate_influences(target_state integer, input_rows jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare row_value jsonb; names text[]:='{}'; statuses text[]:='{}'; baselines numeric[]:='{}'; deltas numeric[]:='{}'; values_array numeric[]:='{}';
 base numeric; delta numeric; sum_changed numeric:=0; sum_unchanged numeric:=0; changed_count integer:=0; unchanged_count integer:=0; count_value integer; idx integer;
 powerless numeric:=0; privileged numeric:=0; result jsonb:='{}'::jsonb; key_name text;
begin
 for row_value in select value from jsonb_array_elements(input_rows) loop
  key_name:=case row_value->>'name' when 'Знать' then 'nobility_influence_pp' when 'Духовенство' then 'clergy_influence_pp' when 'Горожане' then 'burgher_influence_pp' when 'Крестьяне' then 'peasant_influence_pp' end;
  base:=greatest(0,coalesce((row_value->>'influence')::numeric,0)); delta:=coalesce(fauxlore.state_permanent_modifier_total(target_state,array[key_name],null,null),0);
  names:=array_append(names,row_value->>'name'); statuses:=array_append(statuses,coalesce(row_value->>'status',''));baselines:=array_append(baselines,base);deltas:=array_append(deltas,delta);
  if delta<>0 then changed_count:=changed_count+1;sum_changed:=sum_changed+greatest(0,least(1,base+delta)); else unchanged_count:=unchanged_count+1;sum_unchanged:=sum_unchanged+base;end if;
 end loop;
 count_value:=coalesce(cardinality(names),0);if count_value=0 then return result;end if;
 for idx in 1..count_value loop
  if changed_count=0 then base:=baselines[idx];
  elsif unchanged_count=0 then base:=case when sum_changed>0 then greatest(0,least(1,baselines[idx]+deltas[idx]))/sum_changed else 1.0/count_value end;
  elsif deltas[idx]<>0 then base:=case when sum_changed>1 then greatest(0,least(1,baselines[idx]+deltas[idx]))/sum_changed else greatest(0,least(1,baselines[idx]+deltas[idx])) end;
  elsif sum_changed>=1 then base:=0;
  elsif sum_unchanged>0 then base:=(1-sum_changed)*baselines[idx]/sum_unchanged;
  else base:=(1-sum_changed)/unchanged_count;end if;
  values_array:=array_append(values_array,base);
  if statuses[idx]='Бесправное' then powerless:=powerless+base;else privileged:=privileged+base;end if;
 end loop;
 for idx in 1..count_value loop
  base:=values_array[idx];
  if changed_count>0 and privileged>0 and powerless>.1 then base:=case when statuses[idx]='Бесправное' then base*.1/powerless else base*.9/privileged end;end if;
  result:=result||jsonb_build_object(names[idx],base);
 end loop;
 return result;
end $$;
revoke all on function fauxlore.adjust_estate_influences(integer,jsonb) from public,anon,authenticated;
do $migration$
declare fn text; marker text; replacement text;
begin
 fn:=pg_get_functiondef('fauxlore.effective_estate_loyalties(integer)'::regprocedure);
 marker:=$old$), loyalties as ($old$;
 replacement:=$new$), adjusted_weights as (select fauxlore.adjust_estate_influences(target_state,jsonb_agg(jsonb_build_object('name',name,'status',status,'influence',influence))) values_json from influences), loyalties as ($new$;
 if position(marker in fn)=0 then raise exception 'estate influence CTE hook missing'; end if;fn:=replace(fn,marker,replacement);
 marker:=$old$+influence-case status$old$;
 if position(marker in fn)=0 then raise exception 'estate influence loyalty hook missing'; end if;fn:=replace(fn,marker,$new$+adjusted_influence-case status$new$);
 marker:=$old$from influences cross join cfg$old$;
 replacement:=$new$from (select i.*,(a.values_json->>i.name)::numeric adjusted_influence from influences i cross join adjusted_weights a) influences cross join cfg$new$;
 if position(marker in fn)=0 then raise exception 'estate influence projection hook missing'; end if;fn:=replace(fn,marker,replacement);
 marker:=$old$select name,status,effective_loyalty,influence from loyalties$old$;
 if position(marker in fn)=0 then raise exception 'estate influence output hook missing'; end if;execute replace(fn,marker,$new$select name,status,effective_loyalty,adjusted_influence from loyalties$new$);
end $migration$;
notify pgrst,'reload schema';
