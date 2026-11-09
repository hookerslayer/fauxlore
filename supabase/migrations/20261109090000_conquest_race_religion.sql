-- При завоевании провинция получает официальную расу и религию завоевателя.
-- Также сбрасываются незавершённые ассимиляции прежних расы/религии.
do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to patch conquest outside production candidate';
  end if;
end
$guard$;

do $patch$
declare definition text; marker text; replacement text;
begin
  select pg_get_functiondef('fauxlore.conquest_api(text,integer,jsonb)'::regprocedure) into definition;
  marker := $m$    insert into fauxlore.province_values(province_id, layer, category_id)
      values(target_key, 'states', state_key)
      on conflict (province_id, layer) do update set category_id = excluded.category_id;$m$;
  if position(marker in definition) = 0 then
    raise exception 'Could not locate conquest ownership block';
  end if;
  replacement := marker || $m$

    insert into fauxlore.province_values(province_id, layer, category_id)
      select target_key, 'races', sp.official_race_id
      from fauxlore.state_profiles sp
      where sp.state_id = state_key and sp.official_race_id is not null
      on conflict (province_id, layer) do update set category_id = excluded.category_id;

    insert into fauxlore.province_values(province_id, layer, category_id)
      select target_key, 'religions', sp.official_religion_id
      from fauxlore.state_profiles sp
      where sp.state_id = state_key and sp.official_religion_id is not null
      on conflict (province_id, layer) do update set category_id = excluded.category_id;

    update fauxlore.provinces set
      race_assimilation_turns = null, race_assimilation_target_id = null,
      religion_assimilation_turns = null, religion_assimilation_target_id = null,
      race_assimilation_modifier_applied = 0, religion_assimilation_modifier_applied = 0
      where id = target_key;$m$;
  definition := replace(definition, marker, replacement);
  execute definition;
end
$patch$;
