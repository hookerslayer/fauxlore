create or replace function fauxlore.state_population_growth(target_state integer)
returns jsonb language sql stable security definer set search_path='' as $$
with owned as (select p.*,race.name race from fauxlore.provinces p
join fauxlore.province_values v on v.province_id=p.id and v.layer='states' and v.category_id=target_state
left join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='races'
left join fauxlore.map_categories race on race.layer='races' and race.id=rv.category_id where p.kind='land'),
urban as (select coalesce(sum(population*case province_type when 'Столичная' then .35 when 'Городская' then .2 else 0 end)/nullif(sum(population),0),0) ratio from owned),
modifier as (select greatest(.5,1-greatest(0,ratio-.15)*.5) value from urban),
growth as (select case when count(*) filter(where cfg.config#>>array['raceGrowthModifiers',p.race] is null)>0 then null
else coalesce(sum(round(p.population*.03*(cfg.config#>>array['raceGrowthModifiers',p.race])::numeric*m.value,0)),0) end value
from owned p cross join modifier m cross join fauxlore.economy_parameters cfg where cfg.singleton)
select jsonb_build_object('urbanization_growth_multiplier',m.value,'population_growth',g.value) from modifier m cross join growth g
$$;
revoke all on function fauxlore.state_population_growth(integer) from public,anon,authenticated;
alter function fauxlore.state_indicators(integer) rename to state_indicators_before_urbanization;
create function fauxlore.state_indicators(target_state integer)
returns jsonb language sql stable security definer set search_path='' as $$
select fauxlore.state_indicators_before_urbanization(target_state)||fauxlore.state_population_growth(target_state)
$$;
revoke all on function fauxlore.state_indicators(integer) from public,anon,authenticated;
do $$
declare fn text; marker text:='case when v.layer=''states'' then jsonb_build_object(';
begin
fn:=pg_get_functiondef('fauxlore.map_payload()'::regprocedure);
if position(marker in fn)=0 then raise exception 'Map state layer marker missing'; end if;
execute replace(fn,marker,'case when v.layer=''states'' then fauxlore.state_population_growth(c.id)||jsonb_build_object(');
end $$;
notify pgrst,'reload schema';
