-- Local candidates come from inhabited owned provinces and compatible races.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=pg_get_functiondef('fauxlore.character_lifecycle_api(text,text,jsonb,uuid)'::regprocedure);
  old_fragment:=$old$candidate_race:=race_values[1+floor(random()*cardinality(race_values))::integer];
        select id into candidate_religion from fauxlore.map_categories where layer='religions' order by random() limit 1;$old$;
  new_fragment:=$new$select race.category_id,faith.category_id into candidate_race,candidate_religion
        from fauxlore.province_values owner
        join fauxlore.provinces p on p.id=owner.province_id and p.kind='land' and p.population>0
        join fauxlore.province_values race on race.province_id=p.id and race.layer='races' and race.category_id=any(race_values)
        join fauxlore.province_values faith on faith.province_id=p.id and faith.layer='religions'
        where owner.layer='states' and owner.category_id=state_value
        order by -ln(greatest(random(),0.000000000001))/p.population limit 1;
        if not found then raise sqlstate '22023' using message='Нет населённой провинции с совместимой расой и указанной религией для поиска местного супруга'; end if;$new$;
  if position(old_fragment in fn)=0 then raise exception 'Local marriage candidate generation changed'; end if;
  execute replace(fn,old_fragment,new_fragment);
end
$migration$;
