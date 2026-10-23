-- State indicators, stages 1-2. Internal helpers are not exposed to clients.
alter table fauxlore.state_profiles add column development_limit integer not null default 1000 check (development_limit>=0);

-- Align province value with the client and the existing production/turn rules.
do $$
declare fn text;
begin
  fn:=pg_get_functiondef('fauxlore.province_value_for_state(integer,integer)'::regprocedure);
  fn:=replace(fn,'race_rate:=nullif(cfg#>>array[''raceTaxRates'',race_name],'''')::numeric;',
    'race_rate:=fauxlore.effective_state_tax_rate(target_state,''races'',(select category_id from fauxlore.province_values where province_id=p.id and layer=''races''),cfg);');
  fn:=replace(fn,'religion_rate:=nullif(cfg#>>array[''religionTaxRates'',religion_name],'''')::numeric;',
    'religion_rate:=fauxlore.effective_state_tax_rate(target_state,''religions'',(select category_id from fauxlore.province_values where province_id=p.id and layer=''religions''),cfg);');
  fn:=replace(fn,'from fauxlore.state_profiles where state_id=target_state;', 'from fauxlore.state_profiles where state_id=owner_state;');
  execute fn;
end $$;

create or replace function fauxlore.state_indicators(target_state integer)
returns jsonb language sql stable security definer set search_path='' as $$
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
    coalesce(sum(fauxlore.province_value_for_state(p.id,target_state)) filter(where p.share>0),0) weight,
    coalesce(sum(p.population*p.share*(fauxlore.effective_state_tax_rate(target_state,'races',p.race_id,cfg.config)
      +fauxlore.effective_state_tax_rate(target_state,'religions',p.religion_id,cfg.config))) filter(where p.share>0),0) actual,
    coalesce(sum(p.population*p.share*.2) filter(where p.share>0 and fauxlore.effective_state_tax_rate(target_state,'races',p.race_id,cfg.config) is not null
      and fauxlore.effective_state_tax_rate(target_state,'religions',p.religion_id,cfg.config) is not null),0) baseline
  from unnest(array['Корона','Знать','Духовенство','Горожане','Крестьяне']) e(name) cross join cfg
  left join relevant p on p.belonging=e.name
  left join fauxlore.state_group_politics g on g.state_id=target_state and g.group_type='estate' and g.group_key=e.name
  group by e.name,g.status,g.loyalty
), influences as (
  select *,coalesce(weight/nullif(sum(weight) over(),0),0) influence from estates
), loyalties as (
  select *,greatest(0,least(1,loyalty+influence-case status when 'Ключевое' then .5 when 'Значимое' then .35 else 0 end
    -(case when baseline>0 then actual/baseline else 1 end-1)*coalesce((cfg.config->>'taxLoyaltySensitivity')::numeric,.5))) effective_loyalty
  from influences cross join cfg
), estate_block as (
  select greatest(0,least(1,.5+sum(influence*(effective_loyalty-.6)*2*
    case status when 'Господствующее' then 1 when 'Ключевое' then 1.5 when 'Значимое' then 1 when 'Бесправное' then .25 else 0 end))) value from loyalties
), groups as (
  select v.layer,v.category_id,sum(p.population)::numeric population from owned p
  join fauxlore.province_values v on v.province_id=p.id and v.layer in ('races','religions') group by v.layer,v.category_id
), group_blocks as (
  select l.layer,greatest(0,least(1,case l.layer when 'religions' then .2 else 0 end+
    coalesce(sum(g.population/nullif(t.population,0)*(coalesce(gp.loyalty,.5)-.5)*2),0))) value
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
$$;
revoke all on function fauxlore.state_indicators(integer) from public,anon,authenticated;

create or replace function fauxlore.state_indicators_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; sid integer; prior fauxlore.operations; fp text; result jsonb; limit_value integer;
begin
  a:=fauxlore.current_account();
  sid:=substring(path from '[0-9]+')::integer;
  if path !~ '^(my|admin)/states/[0-9]+/indicators$' then raise sqlstate 'P0002' using message='Метод API не найден'; end if;
  if (path like 'admin/%' and a.role<>'admin') or (a.role<>'admin' and not exists(select 1 from fauxlore.account_states where account_id=a.id and layer='states' and state_id=sid))
    then raise sqlstate '42501' using message='Недостаточно прав'; end if;
  if not exists(select 1 from fauxlore.state_profiles where state_id=sid) then raise sqlstate 'P0002' using message='Государство не найдено'; end if;
  if method='GET' then
    return fauxlore.state_indicators(sid)||jsonb_build_object('last_turn',(select r from fauxlore.turn_economy_reports t
      cross join lateral jsonb_array_elements(t.report) r where (r->>'id')::integer=sid order by t.year desc,t.turn desc limit 1));
  end if;
  if a.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if method<>'PATCH' or request_id is null or jsonb_typeof(body) is distinct from 'object' or body-'development_limit'<>'{}'
    or jsonb_typeof(body->'development_limit') is distinct from 'number' or (body->>'development_limit')!~'^\d+$'
    or (body->>'development_limit')::numeric>2147483647 then raise sqlstate '22023' using message='Лимит должен быть неотрицательным целым числом'; end if;
  fp:=md5(jsonb_build_array(method,path,body)::text);
  perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
  select * into prior from fauxlore.operations o where o.account_id=a.id and o.request_id=state_indicators_api.request_id;
  if found then if prior.fingerprint<>fp then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if; return prior.result; end if;
  limit_value:=(body->>'development_limit')::integer;
  select jsonb_build_object('state_id',sid,'development_limit_before',development_limit,'development_limit',limit_value) into result from fauxlore.state_profiles where state_id=sid for update;
  update fauxlore.state_profiles set development_limit=limit_value where state_id=sid;
  -- Operations is the existing durable, actor-scoped command/audit journal.
  insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,state_indicators_api.request_id,fp,result);
  return result;
end $$;
revoke all on function fauxlore.state_indicators_api(text,text,jsonb,uuid) from public,anon,authenticated;

do $$
declare fn text; marker text:='elsif path=''admin/turn/test'' or path like ''admin/turn/test/%'' then';
begin
  fn:=pg_get_functiondef('public.fauxlore_api(text,text,jsonb,uuid)'::regprocedure);
  if position(marker in fn)=0 then raise exception 'Dispatcher insertion point missing'; end if;
  execute replace(fn,marker,'elsif path ~ ''^(my|admin)/states/[0-9]+/indicators$'' then return fauxlore.state_indicators_api(path,method,body,request_id);'||chr(10)||'  '||marker);
end $$;

-- Capture before duty/character lifecycle updates; apply crime only after
-- every state's production and food report has been calculated.
create or replace function fauxlore.crime_step(coverage numeric,stability numeric)
returns jsonb language sql immutable set search_path='' as $$
with steps as (select case when coverage>=95 then 0 when coverage>=80 then 1 when coverage>=60 then 2 when coverage>=40 then 4 else 6 end food,
  case when stability>=.75 then -1 when stability>=.5 then 0 when stability>=.25 then 1 else 2 end politics)
select jsonb_build_object('food_step_pp',food,'stability_step_pp',politics,'crime_step_pp',greatest(-1,least(6,food+politics))) from steps
$$;
revoke all on function fauxlore.crime_step(numeric,numeric) from public,anon,authenticated;

-- Extend the established, final food-report trigger instead of adding a
-- competing trigger whose ordering could accidentally use new crime rates.
do $$
declare fn text; marker text;
begin
  fn:=pg_get_functiondef('fauxlore.report_food_security_after_turn()'::regprocedure);
  fn:=replace(fn,'state_crime numeric(5,4);','state_crime numeric(5,4); indicators jsonb; steps jsonb; next_crime numeric;');
  marker:='state_crime:=state_row.crime;';
  if position(marker in fn)=0 then raise exception 'Food snapshot marker missing'; end if;
  fn:=replace(fn,marker,marker||chr(10)||'    indicators:=fauxlore.state_indicators(state_row.state_id);');
  marker:='state_item:=jsonb_build_object(';
  fn:=replace(fn,marker,'steps:=fauxlore.crime_step(coverage_pct,(indicators->>''stability'')::numeric);'||chr(10)||
    '    next_crime:=greatest(.02,least(1,state_crime+(steps->>''crime_step_pp'')::numeric/100));'||chr(10)||'    '||marker);
  marker:='''crime_rate_at_turn_start_pct'',round(state_crime*100,2)';
  fn:=replace(fn,marker,marker||','||chr(10)||
    '      ''indicators_at_turn_start'',indicators,''stability_at_turn_start_pct'',round((indicators->>''stability'')::numeric*100,4),'||chr(10)||
    '      ''food_step_pp'',steps->''food_step_pp'',''stability_step_pp'',steps->''stability_step_pp'',''crime_step_pp'',steps->''crime_step_pp'','||chr(10)||
    '      ''crime_rate_after_pct'',round(next_crime*100,2),''crime_change_pp'',round((next_crime-state_crime)*100,2)');
  marker:='  update fauxlore.turn_economy_reports set report=';
  if position(marker in fn)=0 then raise exception 'Food finalization marker missing'; end if;
  fn:=replace(fn,marker,'  update fauxlore.state_profiles sp set crime=(r->>''crime_rate_after_pct'')::numeric/100'||chr(10)||
    '  from jsonb_array_elements(report_value) r where sp.state_id=(r->>''id'')::integer;'||chr(10)||marker);
  execute fn;
end $$;
notify pgrst,'reload schema';
