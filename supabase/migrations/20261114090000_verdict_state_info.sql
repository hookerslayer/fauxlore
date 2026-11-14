-- Расширить каталог модификаторов данными государства для окна вердикта.
do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to patch admin catalog outside production candidate';
  end if;
end
$guard$;

do $patch$
declare definition text; marker text; replacement text;
begin
  select pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure) into definition;
  marker := $m$      'states',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name) order by c.name) from fauxlore.map_categories c where c.layer='states' and (actor.role='admin' or fauxlore.judge_can_review(actor.id,c.id))),'[]'::jsonb),$m$;
  if position(marker in definition) = 0 then
    raise exception 'Could not locate admin catalog states';
  end if;
  replacement := $m$      'states',coalesce((select jsonb_agg(jsonb_build_object(
          'id',c.id,'name',c.name,'form',sp.government_name,
          'race',(select rc.name from fauxlore.map_categories rc where rc.layer='races' and rc.id=sp.official_race_id),
          'religion',(select rel.name from fauxlore.map_categories rel where rel.layer='religions' and rel.id=sp.official_religion_id),
          'treasury',(select coalesce(sum(t.balance),0) from fauxlore.state_treasuries t where t.state_id=c.id and t.estate='Корона'))
        order by c.name)
        from fauxlore.map_categories c left join fauxlore.state_profiles sp on sp.state_id=c.id
        where c.layer='states' and (actor.role='admin' or fauxlore.judge_can_review(actor.id,c.id))),'[]'::jsonb),$m$;
  definition := replace(definition, marker, replacement);
  execute definition;
end
$patch$;
