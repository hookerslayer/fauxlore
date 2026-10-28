-- Shared additive modifier resolver. Principle/race/religion rows deliberately
-- bypass the general modifier cap; only the target mechanic's own cap applies.
create or replace function fauxlore.state_permanent_modifier_total(
  target_state integer, modifier_keys text[], target_province integer default null, target_resource text default null
) returns numeric language plpgsql stable security definer set search_path='' as $function$
declare row_value jsonb; province_row record; local_race text; local_religion text; total numeric:=0; scope_value text;
begin
  if target_province is not null then
    select p.province_type,rv.name race_name,rel.name religion_name into province_row
    from fauxlore.provinces p
    left join fauxlore.province_values race_v on race_v.province_id=p.id and race_v.layer='races'
    left join fauxlore.map_categories rv on rv.layer='races' and rv.id=race_v.category_id
    left join fauxlore.province_values religion_v on religion_v.province_id=p.id and religion_v.layer='religions'
    left join fauxlore.map_categories rel on rel.layer='religions' and rel.id=religion_v.category_id
    where p.id=target_province;
    if not found then return 0; end if;
    local_race:=province_row.race_name; local_religion:=province_row.religion_name;
  end if;
  for row_value in select value from jsonb_array_elements(fauxlore.state_permanent_modifiers(target_state)) value
    where value->>'key'=any(modifier_keys)
  loop
    scope_value:=row_value->>'scope';
    if target_province is not null then
      if scope_value='Регионы' and province_row.province_type<>'Регион' then continue; end if;
      if scope_value='Городские и Столичная' and province_row.province_type not in ('Городская','Столичная') then continue; end if;
      if (row_value->>'source_kind')='race' and (scope_value like 'Провинции %' or scope_value like '% + %') and local_race is distinct from row_value->>'source' then continue; end if;
      if (row_value->>'source_kind')='religion' and (scope_value like 'Провинции %' or scope_value like '% + %') and local_religion is distinct from row_value->>'source' then continue; end if;
      if scope_value like '%+ Металлы' and target_resource is distinct from 'Металлы' then continue; end if;
      if scope_value like '%+ Драгоценные металлы' and target_resource is distinct from 'Драгоценные металлы' then continue; end if;
      if scope_value like '%+ Эфемера' and target_resource is distinct from 'Эфемера' then continue; end if;
      if scope_value like '%+ Животноводство' and target_resource is distinct from 'Животноводство' then continue; end if;
      if scope_value like '%+ Лес' then
        if not exists(select 1 from fauxlore.province_values terrain_v join fauxlore.map_categories terrain on terrain.layer='terrain_type' and terrain.id=terrain_v.category_id where terrain_v.province_id=target_province and terrain.name='Лес') then continue; end if;
      end if;
    else
      if scope_value like 'Провинции %' or scope_value like '% + %' or scope_value in ('Регионы','Городские и Столичная') then continue; end if;
    end if;
    if row_value->>'key'='precious_consumption' and target_resource is not null and target_resource<>'Драгоценные металлы' then continue; end if;
    if row_value->>'key'='other_consumption' and target_resource='Драгоценные металлы' then continue; end if;
    total:=total+coalesce((row_value->>'value')::numeric,0);
  end loop;
  return total;
end $function$;
revoke all on function fauxlore.state_permanent_modifier_total(integer,text[],integer,text) from public,anon,authenticated;

create or replace function fauxlore.effective_province_tax_efficiency(target_state integer,target_province integer)
returns numeric language sql stable security definer set search_path='' as $$
select greatest(0,least(1,fauxlore.province_tax_efficiency(p.province_type)+
  fauxlore.state_permanent_modifier_total(target_state,array['tax_efficiency'],p.id,null)))
from fauxlore.provinces p where p.id=target_province and p.kind='land'
$$;
revoke all on function fauxlore.effective_province_tax_efficiency(integer,integer) from public,anon,authenticated;

-- Apply additive permanent tax-efficiency bonuses in both turn settlement and
-- province appraisal while keeping the Overview's base-efficiency indicator intact.
do $migration$
declare fn text; old_expr text; new_expr text;
begin
  fn:=pg_get_functiondef('fauxlore.turn_api(text,text,jsonb,uuid)'::regprocedure);
  old_expr:='fauxlore.province_tax_efficiency(province_row.province_type)';
  if position(old_expr in fn)=0 then raise exception 'Turn tax-efficiency call not found'; end if;
  execute replace(fn,old_expr,'fauxlore.effective_province_tax_efficiency(beneficiary_id,province_row.id)');
  fn:=pg_get_functiondef('fauxlore.province_value_for_state(integer,integer)'::regprocedure);
  old_expr:='fauxlore.province_tax_efficiency(p.province_type)';
  if position(old_expr in fn)>0 then execute replace(fn,old_expr,'fauxlore.effective_province_tax_efficiency(target_state,p.id)'); end if;
end
$migration$;

-- Apply resource production/consumption modifiers in the authoritative turn
-- settlement, which is also the source for trade-market resource balances.
do $migration$
declare fn text; old_expr text; new_expr text;
begin
  fn:=pg_get_functiondef('fauxlore.finish_trade_value_turn()'::regprocedure);
  old_expr:='*greatest(0,coalesce(p.development,100))::numeric/100*(1-coalesce(owner_profile.crime,.2))*';
  new_expr:='*greatest(0,coalesce(p.development,100))::numeric/100*'||
    '(1+fauxlore.state_permanent_modifier_total(case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'''') ) then occupier.id else owner.id end,'||
    'array[''production'',''urban_production'',''regional_production'',''metal_production'',''ephemera_production''],p.id,r.name))'||
    '*(1-coalesce(owner_profile.crime,.2))*';
  if position(old_expr in fn)=0 then raise exception 'Trade production insertion point not found'; end if;
  fn:=replace(fn,old_expr,new_expr);
  old_expr:='sum(floor(pop.population/10*(res.r->>''consumption'')::numeric)) amount';
  new_expr:='sum(floor(pop.population/10*(res.r->>''consumption'')::numeric*'||
    'greatest(0,1+fauxlore.state_permanent_modifier_total(pop.state_id,'||
    'array[''consumption'',''other_consumption'',''precious_consumption''],null,res.r->>''name'')))) amount';
  if position(old_expr in fn)=0 then raise exception 'Trade consumption insertion point not found'; end if;
  execute replace(fn,old_expr,new_expr);
end
$migration$;

create or replace function fauxlore.state_recruitment(target_state integer)
returns jsonb language sql stable security definer set search_path='' as $$
with cfg as (select config from fauxlore.economy_parameters where singleton),
provinces as (
  select p.*,rv.category_id race_id,case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then
    case when lower(p.occupation)=lower(target.name) then .5 else 0 end
    else case when ov.category_id=target_state then 1 else 0 end end share
  from fauxlore.provinces p join fauxlore.map_categories target on target.layer='states' and target.id=target_state
  left join fauxlore.province_values ov on ov.province_id=p.id and ov.layer='states'
  left join fauxlore.map_categories owner on owner.layer='states' and owner.id=ov.category_id
  left join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='races'
  where p.kind='land' and (ov.category_id=target_state or lower(p.occupation)=lower(target.name))
), modifiers as (
  select fauxlore.state_permanent_modifier_total(target_state,array['recruit_growth'],null,null) recruit_growth,
    fauxlore.state_permanent_modifier_total(target_state,array['recruit_limit'],null,null) recruit_limit
)
select jsonb_build_object(
  'recruit_growth',coalesce(sum(floor(p.population::numeric/1000*
    (cfg.config#>>array['recruitGrowthModifiers',p.province_type])::numeric*p.control/100*p.share*
    (1+m.recruit_growth+fauxlore.state_permanent_modifier_total(target_state,array['regional_recruit_growth','local_recruit_growth'],p.id,null))*
    fauxlore.group_status_effect(target_state,'race',p.race_id,'recruit')*
    fauxlore.group_status_effect(target_state,'religion',(select category_id from fauxlore.province_values where province_id=p.id and layer='religions'),'recruit')*
    (1+sp.crime*(cfg.config#>>'{stateEffects,crimeRecruitBonus}')::numeric)*greatest(0,coalesce(p.development,100))::numeric/100)),0),
  'recruit_limit',coalesce(sum(floor(p.population::numeric/10*
    (cfg.config#>>array['recruitLimitModifiers',p.province_type])::numeric*
    fauxlore.estate_recruit_modifier(p.province_type,p.population,cfg.config)*p.control/100*p.share*
    (1+m.recruit_limit+fauxlore.state_permanent_modifier_total(target_state,array['local_recruit_limit'],p.id,null))*
    fauxlore.group_status_effect(target_state,'race',p.race_id,'recruit')*
    fauxlore.group_status_effect(target_state,'religion',(select category_id from fauxlore.province_values where province_id=p.id and layer='religions'),'recruit')*
    greatest(0,coalesce(p.development,100))::numeric/100)),0))
from cfg join fauxlore.state_profiles sp on sp.state_id=target_state cross join modifiers m left join provinces p on true
$$;
revoke all on function fauxlore.state_recruitment(integer) from public,anon,authenticated;

-- Province-based trade influence and trade-zone forecasts share the same local
-- additive bonuses from active principles and present faiths.
do $migration$
declare fn text; old_expr text; new_expr text;
begin
  fn:=pg_get_functiondef('fauxlore.trade_zone_influence(integer,integer)'::regprocedure);
  old_expr:='*greatest(0,coalesce(p.development,100))::numeric/100';
  new_expr:=old_expr||chr(10)||' *(1+fauxlore.state_permanent_modifier_total(state_value,array[''trade_influence''],p.id,null))';
  if position(old_expr in fn)=0 then raise exception 'Trade influence insertion point not found'; end if;
  execute replace(fn,old_expr,new_expr);
end
$migration$;

-- Passive prestige is credited once whenever the game calendar advances.
create or replace function fauxlore.apply_permanent_prestige_on_turn()
returns trigger language plpgsql security definer set search_path='' as $function$
declare state_row record; change_value numeric;
begin
  if (new.year,new.turn) is not distinct from (old.year,old.turn) then return new; end if;
  for state_row in select state_id from fauxlore.state_profiles order by state_id loop
    change_value:=fauxlore.state_permanent_modifier_total(state_row.state_id,array['prestige'],null,null);
    if change_value<>0 then update fauxlore.state_profiles set prestige=greatest(0,coalesce(prestige,0)+change_value) where state_id=state_row.state_id; end if;
  end loop;
  return new;
end $function$;
revoke all on function fauxlore.apply_permanent_prestige_on_turn() from public,anon,authenticated;
drop trigger if exists apply_permanent_prestige_on_turn on fauxlore.game_calendar;
create trigger apply_permanent_prestige_on_turn after update of year,turn on fauxlore.game_calendar
for each row execute function fauxlore.apply_permanent_prestige_on_turn();

notify pgrst,'reload schema';
