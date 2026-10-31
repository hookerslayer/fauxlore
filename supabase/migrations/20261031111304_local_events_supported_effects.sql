-- Definitions with built-in race, terrain or province-type conditions cannot be
-- represented by an unrestricted event effect. Offer their generic equivalent.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=pg_get_functiondef('public.local_events_api(text,jsonb)'::regprocedure);
  old_fragment:=$old$where modifier_key<>'spy_growth' and condition_text<>'Максимум' and unit not in ('статус')$old$;
  new_fragment:=$new$where modifier_key not in ('spy_growth','livestock_population_growth','regional_recruit_growth','local_recruit_growth','local_recruit_limit',
            'regional_production','urban_production','metal_production','ephemera_production',
            'urban_development','regional_development','forest_development','livestock_development','metal_development','precious_development','ephemera_development')
            and condition_text<>'Максимум' and unit not in ('статус')$new$;
  if position(old_fragment in fn)=0 then raise exception 'Event catalogue filter changed'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:=$old$and d.modifier_key<>'spy_growth' and d.condition_text<>'Максимум' and d.unit<>'статус' limit 1$old$;
  new_fragment:=$new$and d.modifier_key not in ('spy_growth','livestock_population_growth','regional_recruit_growth','local_recruit_growth','local_recruit_limit',
            'regional_production','urban_production','metal_production','ephemera_production',
            'urban_development','regional_development','forest_development','livestock_development','metal_development','precious_development','ephemera_development')
          and d.condition_text<>'Максимум' and d.unit<>'статус' limit 1$new$;
  if position(old_fragment in fn)=0 then raise exception 'Event validation filter changed'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $migration$;
