CREATE OR REPLACE FUNCTION fauxlore.estate_status_for(target_state integer, target_estate text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p jsonb; authority_value text; economy_value text; i integer; result text;
begin
  select principles into p from fauxlore.state_profiles where state_id=target_state;
  authority_value:=p->>'authority'; economy_value:=p->>'economy';
  i:=array_position(array['Знать','Духовенство','Горожане','Крестьяне'],target_estate);
  if i is null then return '—'; end if;
  result:=case authority_value
    when 'Династия' then (array['Ключевое','Значимое','Бесправное','Бесправное'])[i]
    when 'Магистрат' then (array['Значимое','Ключевое','Ключевое','Бесправное'])[i]
    when 'Клир' then (array['Бесправное','Ключевое','Бесправное','Бесправное'])[i]
    when 'Диктат' then (array['Бесправное','Значимое','Бесправное','Бесправное'])[i]
    when 'Вече' then (array['Бесправное','Значимое','Значимое','Ключевое'])[i]
    else '—' end;
  if economy_value='Крепостничество' and i in (1,4) then result:=case i when 1 then 'Ключевое' else 'Бесправное' end;
  elsif economy_value='Гильдии' and i=3 then result:='Ключевое';
  elsif economy_value='Адмиралтейство' and i=3 then result:='Ключевое';
  elsif economy_value='Корсарство' and i=3 then result:='Значимое';
  elsif economy_value='Работорговля' and i=4 then result:='Бесправное'; end if;
  return coalesce(result,'—');
end $function$;

CREATE OR REPLACE FUNCTION fauxlore.ensure_state_group_politics(target_state integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  insert into fauxlore.state_group_politics(state_id,group_type,group_key,status)
  select target_state,'estate',e.name,fauxlore.estate_status_for(target_state,e.name)
  from unnest(array['Знать','Духовенство','Горожане','Крестьяне']) e(name)
  on conflict(state_id,group_type,group_key) do update set status=excluded.status;
  insert into fauxlore.state_group_politics(state_id,group_type,group_key,status)
  select distinct target_state,case v.layer when 'races' then 'race' else 'religion' end,v.category_id::text,
    case when v.layer='races' and v.category_id=sp.official_race_id then 'Официальная'
         when v.layer='religions' and v.category_id=sp.official_religion_id then 'Официальная'
         else 'Невмешательство' end
  from fauxlore.state_profiles sp
  join fauxlore.province_values sv on sv.layer='states' and sv.category_id=target_state
  join fauxlore.province_values v on v.province_id=sv.province_id and v.layer in ('races','religions')
  where sp.state_id=target_state
  on conflict(state_id,group_type,group_key) do nothing;
end $function$;

CREATE OR REPLACE FUNCTION fauxlore.state_indicators_before_urbanization(target_state integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
with cfg as (select config from fauxlore.economy_parameters where singleton),
owned as (
  select p.* from fauxlore.provinces p join fauxlore.province_values v on v.province_id=p.id and v.layer='states'
  where p.kind='land' and v.category_id=target_state
), aggregates as (
  select count(*) province_count,coalesce(sum(population),0) population,
    coalesce(sum(population*case province_type when 'Столичная' then .35 when 'Городская' then .2 else 0 end),0) urban,
    sum(development) development,count(*) filter(where development is null) missing_development
  from owned
), relevant as (
  select p.*,case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,''))
    then case when lower(p.occupation)=lower(target.name) then .5 else 0 end
    else case when ov.category_id=target_state then 1 else 0 end end share,
    rv.category_id race_id,rel.category_id religion_id
  from fauxlore.provinces p
  left join fauxlore.province_values ov on ov.province_id=p.id and ov.layer='states'
  left join fauxlore.map_categories owner on owner.layer='states' and owner.id=ov.category_id
  join fauxlore.map_categories target on target.layer='states' and target.id=target_state
  left join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='races'
  left join fauxlore.province_values rel on rel.province_id=p.id and rel.layer='religions'
  where p.kind='land' and (ov.category_id=target_state or lower(p.occupation)=lower(target.name))
), estates as (
  select e.name,coalesce(g.status,fauxlore.estate_status_for(target_state,e.name)) status,coalesce(g.loyalty,.5) loyalty,
    coalesce(sum(fauxlore.province_value_for_state(p.id,target_state)*ep.population/nullif(p.population,0)),0) weight,
    coalesce(sum(ep.population*p.share*fauxlore.estate_tax_rate(target_state,e.name,cfg.config)),0) actual,
    coalesce(sum(ep.population*p.share*(cfg.config#>>array['estateTaxRates',e.name])::numeric),0) baseline
  from unnest(array['Знать','Духовенство','Горожане','Крестьяне']) e(name) cross join cfg
  left join relevant p on p.share>0
  left join lateral fauxlore.estate_population(p.province_type,p.population) ep on ep.estate=e.name
  left join fauxlore.state_group_politics g on g.state_id=target_state and g.group_type='estate' and g.group_key=e.name
  group by e.name,g.status,g.loyalty
), influences as (
  select *,coalesce(weight/nullif(sum(weight) over(),0),0) influence from estates
), loyalties as (
  select *,greatest(0,least(1,loyalty+case when name in ('Знать','Духовенство') then least((cfg.config#>>'{stateEffects,corruptionLoyaltyCap}')::numeric,(select corruption from fauxlore.state_profiles where state_id=target_state)/(cfg.config#>>'{stateEffects,corruptionLoyaltyDivisor}')::numeric) else 0 end+influence-case status when 'Ключевое' then .5 when 'Значимое' then .35 else 0 end
    -(case when baseline>0 then actual/baseline else 1 end-1)*coalesce((cfg.config->>'taxLoyaltySensitivity')::numeric,.5))) effective_loyalty
  from influences cross join cfg
), estate_block as (
  select greatest(0,least(1,.5+sum(influence*(effective_loyalty-.6)*2*
    case status when 'Ключевое' then 1.5 when 'Значимое' then 1 when 'Бесправное' then .25 else 0 end))) value from loyalties
), groups as (
  select v.layer,v.category_id,sum(p.population)::numeric population from owned p
  join fauxlore.province_values v on v.province_id=p.id and v.layer in ('races','religions') group by v.layer,v.category_id
), group_blocks as (
  select l.layer,greatest(0,least(1,case l.layer when 'religions' then .2 else 0 end+
    coalesce(sum(g.population/nullif(t.population,0)*(greatest(0,least(1,coalesce(gp.loyalty,.5)+fauxlore.group_status_loyalty_modifier(target_state,case l.layer when 'races' then 'race' else 'religion' end,g.category_id)))-.5)*2),0))) value
  from (values('races'),('religions')) l(layer)
  left join groups g on g.layer=l.layer
  left join (select layer,sum(population) population from groups group by layer) t on t.layer=l.layer
  left join fauxlore.state_group_politics gp on gp.state_id=target_state and gp.group_key=g.category_id::text
    and gp.group_type=case l.layer when 'races' then 'race' else 'religion' end
  group by l.layer
)
select jsonb_build_object('state_id',target_state,'population',a.population,'urban_population',a.urban,
  'rural_population',a.population-a.urban,'urbanization',coalesce(a.urban/nullif(a.population,0),0),
  'province_count',a.province_count,'total_development',case when a.province_count=0 then 0 else a.development end,
  'missing_development_count',a.missing_development,'development_limit',sp.development_limit,
  'overload',greatest(0,coalesce(a.development,0)-sp.development_limit),
  'overload_ratio',case when sp.development_limit>0 then greatest(0,coalesce(a.development,0)-sp.development_limit)::numeric/sp.development_limit else null end,
  'stability',(eb.value+(select sum(value) from group_blocks))/3,
  'stability_blocks',jsonb_build_object('estate',eb.value,'race',(select value from group_blocks where layer='races'),'religion',(select value from group_blocks where layer='religions')),
  'crime',sp.crime,'corruption',sp.corruption)
from aggregates a cross join estate_block eb join fauxlore.state_profiles sp on sp.state_id=target_state
$function$;

create table if not exists fauxlore.retired_crown_politics as
select * from fauxlore.state_group_politics where group_type='estate' and group_key='Корона';
revoke all on fauxlore.retired_crown_politics from public,anon,authenticated;
delete from fauxlore.state_group_politics where group_type='estate' and group_key='Корона';


