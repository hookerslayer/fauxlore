insert into fauxlore.permanent_modifier_definitions(source_kind,source_key,modifier_key,effect,value,unit,scope,condition_text) values('constructor','Назначение','population_growth_pp','Прирост населения',0,'п.п.','Государство','');
do $migration$
declare fn text; marker text; replacement text;
begin
 fn:=pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure);
 marker:=$old$'tax_efficiency','population_growth','development'$old$;
 if position(marker in fn)=0 then raise exception 'population scope hook missing'; end if;fn:=replace(fn,marker,$new$'tax_efficiency','population_growth','population_growth_pp','development'$new$);execute fn;
 fn:=pg_get_functiondef('fauxlore.state_population_growth(integer)'::regprocedure);
 marker:=$old$p.population*.015*(cfg.config#>>array['raceGrowthModifiers',p.race])::numeric$old$;
 replacement:=$new$p.population*(.015*(cfg.config#>>array['raceGrowthModifiers',p.race])::numeric+fauxlore.state_permanent_modifier_total(target_state,array['population_growth_pp'],p.id,null))$new$;
 if position(marker in fn)=0 then raise exception 'population growth projection hook missing'; end if;fn:=replace(fn,marker,replacement);
 marker:=$old$coalesce(sum(floor(p.population$old$;
 if position(marker in fn)=0 then raise exception 'population lower-bound hook missing'; end if; fn:=replace(fn,marker,$new$coalesce(sum(greatest(-p.population,floor(p.population$new$);
 marker:=$old$where v.province_id=p.id and v.layer='resources'))))),0)$old$;
 if position(marker in fn)=0 then raise exception 'population projection closing hook missing'; end if; fn:=replace(fn,marker,$new$where v.province_id=p.id and v.layer='resources')))))),0)$new$);execute fn;
 fn:=pg_get_functiondef('fauxlore.apply_turn_population_and_recruit_growth()'::regprocedure);
 marker:=$old$province_row.population*.015*(cfg#>>array['raceGrowthModifiers',province_row.race])::numeric$old$;
 replacement:=$new$province_row.population*(.015*(cfg#>>array['raceGrowthModifiers',province_row.race])::numeric+fauxlore.state_permanent_modifier_total(state_row.state_id,array['population_growth_pp'],province_row.id,null))$new$;
 if position(marker in fn)=0 then raise exception 'population growth turn hook missing'; end if;fn:=replace(fn,marker,replacement);
 marker:=$old$province_growth:=floor(province_row.population$old$;
 if position(marker in fn)=0 then raise exception 'population turn lower-bound hook missing'; end if;fn:=replace(fn,marker,$new$province_growth:=greatest(-province_row.population,floor(province_row.population$new$);
 marker:=$old$where v.province_id=province_row.id and v.layer='resources'))))::integer;$old$;
 if position(marker in fn)=0 then raise exception 'population turn closing hook missing'; end if;fn:=replace(fn,marker,$new$where v.province_id=province_row.id and v.layer='resources')))))::integer;$new$);
 marker:=$old$if province_growth>0 then$old$;
 if position(marker in fn)=0 then raise exception 'population turn sign hook missing'; end if;execute replace(fn,marker,$new$if province_growth<>0 then$new$);
end $migration$;
notify pgrst,'reload schema';
