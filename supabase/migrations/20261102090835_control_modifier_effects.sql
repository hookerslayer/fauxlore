insert into fauxlore.permanent_modifier_definitions(source_kind,source_key,modifier_key,effect,value,unit,scope,condition_text) values('constructor','Назначение','control_modifier_pp','КМ',0,'п.п.','Государство','');
create function fauxlore.effective_province_control(province_key integer,target_state integer default null) returns numeric
language sql stable security definer set search_path='' as $$
 select greatest(0,least(100,coalesce(p.control,100)+100*fauxlore.state_permanent_modifier_total(coalesce(target_state,case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then occupier.id else ov.category_id end),array['control_modifier_pp'],p.id,null)))
 from fauxlore.provinces p left join fauxlore.province_values ov on ov.province_id=p.id and ov.layer='states'
 left join fauxlore.map_categories owner on owner.layer='states' and owner.id=ov.category_id
 left join fauxlore.map_categories occupier on occupier.layer='states' and lower(occupier.name)=lower(p.occupation)
 where p.id=province_key
$$;
revoke all on function fauxlore.effective_province_control(integer,integer) from public,anon,authenticated;
do $migration$
declare fn text; marker text; replacement text; signature text;
begin
 fn:=pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure);
 marker:=$old$'tax_efficiency','population_growth','population_growth_pp','development'$old$;
 if position(marker in fn)=0 then raise exception 'control scope hook missing'; end if;
 execute replace(fn,marker,$new$'tax_efficiency','population_growth','population_growth_pp','control_modifier_pp','development'$new$);
 fn:=pg_get_functiondef('fauxlore.state_recruitment(integer)'::regprocedure);
 marker:=$old$p.control/100*p.share$old$;
 if position(marker in fn)=0 then raise exception 'recruit control hook missing'; end if;execute replace(fn,marker,$new$fauxlore.effective_province_control(p.id,target_state)/100*p.share$new$);
 fn:=pg_get_functiondef('fauxlore.province_value_for_state(integer,integer)'::regprocedure);
 marker:=$old$coalesce(p.control,100)$old$;
 if position(marker in fn)=0 then raise exception 'province value control hook missing'; end if;execute replace(fn,marker,$new$fauxlore.effective_province_control(p.id,target_state)$new$);
 foreach signature in array array['fauxlore.clear_trade_zones_after_budget()','fauxlore.finish_trade_value_turn()','fauxlore.report_food_security_after_turn()','fauxlore.trade_resource_surplus(integer,text)'] loop
   fn:=pg_get_functiondef(signature::regprocedure);marker:=$old$coalesce(p.control,100)::numeric/100$old$;
   if position(marker in fn)=0 then raise exception 'trade control hook missing %',signature; end if;execute replace(fn,marker,$new$fauxlore.effective_province_control(p.id,null)/100$new$);
 end loop;
 fn:=pg_get_functiondef('fauxlore.turn_api(text,text,jsonb,uuid)'::regprocedure);
 marker:=$old$greatest(0,least(100,coalesce(province_row.control,100)))::numeric/100$old$;
 if position(marker in fn)=0 then raise exception 'turn tax control hook missing'; end if;execute replace(fn,marker,$new$fauxlore.effective_province_control(province_row.id,beneficiary_id)/100$new$);
 fn:=pg_get_functiondef('fauxlore.militia_preview(integer)'::regprocedure);
 marker:=$old$greatest(0,least(100,coalesce(province_row.control,100)))/100$old$;
 if position(marker in fn)=0 then raise exception 'militia control hook missing'; end if;execute replace(fn,marker,$new$fauxlore.effective_province_control(province_row.id,state_key)/100$new$);
 fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
 marker:=$old$coalesce(p.control,100)=100$old$;
 if position(marker in fn)=0 then raise exception 'military control hook missing'; end if;execute replace(fn,marker,$new$fauxlore.effective_province_control(p.id,sid)=100$new$);
 fn:=pg_get_functiondef('public.military_transport_api(text,bigint,bigint,integer)'::regprocedure);
 marker:=$old$coalesce(land_row.control,100)<100$old$;
 if position(marker in fn)=0 then raise exception 'transport origin control hook missing'; end if;fn:=replace(fn,marker,$new$fauxlore.effective_province_control(land_row.id,army.state_id)<100$new$);
 marker:=$old$coalesce(target_row.control,100)<100$old$;
 if position(marker in fn)=0 then raise exception 'transport destination control hook missing'; end if;execute replace(fn,marker,$new$fauxlore.effective_province_control(target_row.id,army.state_id)<100$new$);
end $migration$;
notify pgrst,'reload schema';
