insert into fauxlore.permanent_modifier_definitions(source_kind,source_key,modifier_key,effect,value,unit,scope,condition_text) values
 ('constructor','Назначение','crime_pp','Преступность',0,'п.п.','Государство',''),
 ('constructor','Назначение','corruption_pp','Коррупция',0,'п.п.','Государство','');
create function fauxlore.effective_social_rate(target_state integer,rate_kind text,base_value numeric) returns numeric
language sql stable security definer set search_path='' as $$
 select greatest(0,least(1,coalesce(base_value,.2)+case when target_state is null then 0 else fauxlore.state_permanent_modifier_total(target_state,array[case rate_kind when 'crime' then 'crime_pp' else 'corruption_pp' end],null,null) end))
$$;
revoke all on function fauxlore.effective_social_rate(integer,text,numeric) from public,anon,authenticated;
do $migration$
declare fn text; signature text; old_part text; new_part text;
begin
 foreach signature in array array['fauxlore.clear_trade_zones_after_budget()','fauxlore.finish_trade_value_turn()','fauxlore.report_food_security_after_turn()','fauxlore.trade_resource_surplus(integer,text)'] loop
  fn:=pg_get_functiondef(signature::regprocedure);old_part:='coalesce(owner_profile.crime,.2)';
  if position(old_part in fn)=0 then raise exception 'crime production hook missing: %',signature;end if;
  fn:=replace(fn,old_part,$new$fauxlore.effective_social_rate(owner_profile.state_id,'crime',owner_profile.crime)$new$);execute fn;
 end loop;
 fn:=pg_get_functiondef('fauxlore.state_cost_multiplier(integer)'::regprocedure);
 fn:=replace(fn,'coalesce(sp.corruption,0)',$new$fauxlore.effective_social_rate(target_state,'corruption',sp.corruption)$new$);
 fn:=replace(fn,'coalesce(sp.crime,0)',$new$fauxlore.effective_social_rate(target_state,'crime',sp.crime)$new$);execute fn;
 fn:=pg_get_functiondef('fauxlore.state_indicators_before_urbanization(integer)'::regprocedure);
 old_part:=$old$'crime',sp.crime,'corruption',sp.corruption$old$;
 if position(old_part in fn)=0 then raise exception 'social indicators missing';end if;
 fn:=replace(fn,old_part,$new$'crime',fauxlore.effective_social_rate(target_state,'crime',sp.crime),'corruption',fauxlore.effective_social_rate(target_state,'corruption',sp.corruption)$new$);execute fn;
 fn:=pg_get_functiondef('fauxlore.state_indicators(integer)'::regprocedure);
 old_part:='sp.corruption/';if position(old_part in fn)=0 then raise exception 'corruption bonus missing';end if;
 fn:=replace(fn,old_part,$new$fauxlore.effective_social_rate(target_state,'corruption',sp.corruption)/$new$);execute fn;
 fn:=pg_get_functiondef('fauxlore.state_population_growth(integer)'::regprocedure);
 old_part:='sp.crime';if position(old_part in fn)=0 then raise exception 'crime growth missing';end if;
 fn:=replace(fn,old_part,$new$fauxlore.effective_social_rate(target_state,'crime',sp.crime)$new$);
 fn:=replace(fn,'sp.corruption',$new$fauxlore.effective_social_rate(target_state,'corruption',sp.corruption) corruption$new$);execute fn;
 fn:=pg_get_functiondef('fauxlore.state_recruitment(integer)'::regprocedure);
 old_part:='sp.crime';if position(old_part in fn)=0 then raise exception 'crime recruits missing';end if;
 fn:=replace(fn,old_part,$new$fauxlore.effective_social_rate(target_state,'crime',sp.crime)$new$);execute fn;
 fn:=pg_get_functiondef('fauxlore.effective_estate_loyalties(integer)'::regprocedure);
 old_part:='(select corruption from fauxlore.state_profiles where state_id=target_state)';
 if position(old_part in fn)=0 then raise exception 'estate corruption missing';end if;
 fn:=replace(fn,old_part,$new$(select fauxlore.effective_social_rate(target_state,'corruption',corruption) from fauxlore.state_profiles where state_id=target_state)$new$);execute fn;
 fn:=pg_get_functiondef('fauxlore.province_value_for_state(integer,integer)'::regprocedure);
 old_part:='coalesce(crime,.2)';if position(old_part in fn)=0 then raise exception 'province production crime missing';end if;
 fn:=replace(fn,old_part,$new$fauxlore.effective_social_rate(owner_state,'crime',crime)$new$);
 fn:=replace(fn,'(select crime from fauxlore.state_profiles where state_id=target_state)',$new$(select fauxlore.effective_social_rate(target_state,'crime',crime) from fauxlore.state_profiles where state_id=target_state)$new$);
 fn:=replace(fn,'(select corruption from fauxlore.state_profiles where state_id=target_state)',$new$(select fauxlore.effective_social_rate(target_state,'corruption',corruption) from fauxlore.state_profiles where state_id=target_state)$new$);execute fn;
 fn:=pg_get_functiondef('fauxlore.turn_api(text,text,jsonb,uuid)'::regprocedure);
 old_part:='(select crime from fauxlore.state_profiles where state_id=beneficiary_id)';
 if position(old_part in fn)=0 then raise exception 'turn taxation crime missing';end if;
 fn:=replace(fn,old_part,$new$(select fauxlore.effective_social_rate(beneficiary_id,'crime',crime) from fauxlore.state_profiles where state_id=beneficiary_id)$new$);
 fn:=replace(fn,'(select corruption from fauxlore.state_profiles where state_id=beneficiary_id)',$new$(select fauxlore.effective_social_rate(beneficiary_id,'corruption',corruption) from fauxlore.state_profiles where state_id=beneficiary_id)$new$);execute fn;
end $migration$;
do $migration$
declare fn text; marker text;
begin
 fn:=pg_get_functiondef('fauxlore.report_food_security_after_turn()'::regprocedure);
 marker:=$old$coalesce(sp.crime,.2) crime$old$;
 if position(marker in fn)=0 then raise exception 'turn crime base missing';end if;
 fn:=replace(fn,marker,$new$coalesce(sp.crime,.2) crime,coalesce(sp.corruption,.2) corruption$new$);
 marker:=$old$state_crime:=state_row.crime;$old$;
 if position(marker in fn)=0 then raise exception 'turn crime start missing';end if;
 fn:=replace(fn,marker,$new$state_crime:=fauxlore.effective_social_rate(state_row.state_id,'crime',state_row.crime);$new$);
 marker:=$old$(indicators->>'corruption')::numeric+(corruption_steps->>'corruption_step_pp')::numeric/100$old$;
 if position(marker in fn)=0 then raise exception 'turn corruption base update missing';end if;
 fn:=replace(fn,marker,$new$state_row.corruption+(corruption_steps->>'corruption_step_pp')::numeric/100$new$);
 marker:=$old$state_crime+(steps->>'crime_step_pp')::numeric/100$old$;
 if position(marker in fn)=0 then raise exception 'turn crime base update missing';end if;
 fn:=replace(fn,marker,$new$state_row.crime+(steps->>'crime_step_pp')::numeric/100$new$);
 marker:=$old$'crime_rate_after_pct',round(next_crime*100,2),'crime_change_pp',round((next_crime-state_crime)*100,2),$old$;
 if position(marker in fn)=0 then raise exception 'turn crime report missing';end if;
 fn:=replace(fn,marker,$new$'crime_base_after',next_crime,'crime_rate_after_pct',round(fauxlore.effective_social_rate(state_row.state_id,'crime',next_crime)*100,2),'crime_change_pp',round((fauxlore.effective_social_rate(state_row.state_id,'crime',next_crime)-state_crime)*100,2),$new$);
 marker:=$old$'corruption_rate_at_turn_start_pct',(indicators->>'corruption')::numeric*100,'corruption_rate_after_pct',next_corruption*100,$old$;
 if position(marker in fn)=0 then raise exception 'turn corruption report missing';end if;
 fn:=replace(fn,marker,$new$'corruption_base_after',next_corruption,'corruption_rate_at_turn_start_pct',(indicators->>'corruption')::numeric*100,'corruption_rate_after_pct',fauxlore.effective_social_rate(state_row.state_id,'corruption',next_corruption)*100,$new$);
 marker:=$old$(next_corruption-(indicators->>'corruption')::numeric)*100$old$;
 if position(marker in fn)=0 then raise exception 'turn corruption change missing';end if;
 fn:=replace(fn,marker,$new$(fauxlore.effective_social_rate(state_row.state_id,'corruption',next_corruption)-(indicators->>'corruption')::numeric)*100$new$);
 marker:=$old$next_corruption/(effects_config#>>'{stateEffects,corruptionLoyaltyDivisor}')::numeric$old$;
 -- report the effective next-turn effect while storing the unmodified base.
 fn:=replace(fn,marker,$new$fauxlore.effective_social_rate(state_row.state_id,'corruption',next_corruption)/(effects_config#>>'{stateEffects,corruptionLoyaltyDivisor}')::numeric$new$);
 marker:=$old$crime=(r->>'crime_rate_after_pct')::numeric/100,corruption=(r->>'corruption_rate_after_pct')::numeric/100$old$;
 if position(marker in fn)=0 then raise exception 'turn base persistence missing';end if;
 fn:=replace(fn,marker,$new$crime=(r->>'crime_base_after')::numeric,corruption=(r->>'corruption_base_after')::numeric$new$);execute fn;
end $migration$;
do $migration$
declare fn text; signature text; old_part text;
begin
 foreach signature in array array['fauxlore.map_payload_unfiltered()','fauxlore.province_payload(fauxlore.provinces)'] loop
  fn:=pg_get_functiondef(signature::regprocedure);
  old_part:='(select sp.crime from fauxlore.state_profiles sp where sp.state_id=c.id)';
  if position(old_part in fn)=0 then raise exception 'map crime field missing: %',signature;end if;
  fn:=replace(fn,old_part,$new$(select fauxlore.effective_social_rate(c.id,'crime',sp.crime) from fauxlore.state_profiles sp where sp.state_id=c.id)$new$);
  fn:=replace(fn,'(select sp.corruption from fauxlore.state_profiles sp where sp.state_id=c.id)',$new$(select fauxlore.effective_social_rate(c.id,'corruption',sp.corruption) from fauxlore.state_profiles sp where sp.state_id=c.id)$new$);
  fn:=replace(fn,'coalesce(sp.crime,0.2)',$new$fauxlore.effective_social_rate(sp.state_id,'crime',sp.crime)$new$);
  fn:=replace(fn,'coalesce(sp.corruption,0.2)',$new$fauxlore.effective_social_rate(sp.state_id,'corruption',sp.corruption)$new$);execute fn;
 end loop;
 fn:=pg_get_functiondef('fauxlore.game_state_api(text,text,jsonb,uuid)'::regprocedure);
 old_part:='coalesce(sp.corruption,0.2)';if position(old_part in fn)=0 then raise exception 'state profile corruption missing';end if;
 fn:=replace(fn,old_part,$new$fauxlore.effective_social_rate(sp.state_id,'corruption',sp.corruption)$new$);
 fn:=replace(fn,'coalesce(sp.crime,0.2)',$new$fauxlore.effective_social_rate(sp.state_id,'crime',sp.crime)$new$);execute fn;
 fn:=pg_get_functiondef('fauxlore.state_api(text,text,jsonb,uuid)'::regprocedure);
 old_part:='coalesce(s.corruption,0.2)';if position(old_part in fn)=0 then raise exception 'admin state corruption missing';end if;
 fn:=replace(fn,old_part,$new$fauxlore.effective_social_rate(s.state_id,'corruption',s.corruption)$new$);execute fn;
 fn:=pg_get_functiondef('public.judge_state_statistics_api()'::regprocedure);
 fn:=replace(fn,$old$'crime',sp.crime,'corruption',sp.corruption$old$,$new$'crime',fauxlore.effective_social_rate(sp.state_id,'crime',sp.crime),'corruption',fauxlore.effective_social_rate(sp.state_id,'corruption',sp.corruption)$new$);execute fn;
end $migration$;
notify pgrst,'reload schema';
