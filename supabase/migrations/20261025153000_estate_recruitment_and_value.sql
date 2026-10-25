create or replace function fauxlore.estate_recruit_modifier(province_kind text, inhabitants bigint, cfg jsonb)
returns numeric language sql stable security invoker set search_path='' as $$
select case when coalesce(inhabitants,0)<=0 then 0
  else coalesce(sum(e.population::numeric*coalesce((cfg#>>array['estateRecruitModifiers',e.estate])::numeric,0)),0)/inhabitants end
from fauxlore.estate_population(province_kind,inhabitants) e
$$;
revoke all on function fauxlore.estate_recruit_modifier(text,bigint,jsonb) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION fauxlore.state_recruitment(target_state integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
with cfg as (select config from fauxlore.economy_parameters where singleton),
provinces as (select p.*,rv.category_id race_id,case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then
  case when lower(p.occupation)=lower(target.name) then .5 else 0 end else case when ov.category_id=target_state then 1 else 0 end end share
from fauxlore.provinces p join fauxlore.map_categories target on target.layer='states' and target.id=target_state
left join fauxlore.province_values ov on ov.province_id=p.id and ov.layer='states'
left join fauxlore.map_categories owner on owner.layer='states' and owner.id=ov.category_id left join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='races'
where p.kind='land' and (ov.category_id=target_state or lower(p.occupation)=lower(target.name)))
select jsonb_build_object('recruit_growth',coalesce(sum(round(p.population::numeric/1000*(cfg.config#>>array['recruitGrowthModifiers',p.province_type])::numeric*p.control/100*p.share*fauxlore.group_status_effect(target_state,'race',p.race_id,'recruit')*fauxlore.group_status_effect(target_state,'religion',(select category_id from fauxlore.province_values where province_id=p.id and layer='religions'),'recruit')*(1+sp.crime*(cfg.config#>>'{stateEffects,crimeRecruitBonus}')::numeric)*greatest(0,coalesce(p.development,100))::numeric/100,0)),0),
  'recruit_limit',coalesce(sum(round(p.population::numeric/100*(cfg.config#>>array['recruitLimitModifiers',p.province_type])::numeric*
    fauxlore.estate_recruit_modifier(p.province_type,p.population,cfg.config)*p.control/100*p.share*fauxlore.group_status_effect(target_state,'race',p.race_id,'recruit')*fauxlore.group_status_effect(target_state,'religion',(select category_id from fauxlore.province_values where province_id=p.id and layer='religions'),'recruit')*greatest(0,coalesce(p.development,100))::numeric/100,0)),0))
from cfg join fauxlore.state_profiles sp on sp.state_id=target_state left join provinces p on true
$function$;

CREATE OR REPLACE FUNCTION fauxlore.province_value_for_state(target_province integer, target_state integer)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p fauxlore.provinces; cfg jsonb; state_name text; owner_state integer;
  race_name text; religion_name text; resource_name text; tax_mod numeric; prod_mod numeric;
  trade_mod numeric; trade_base numeric; trade_status_mod numeric; race_rate numeric; religion_rate numeric;
  resource_value numeric:=0; resource_prod numeric:=0; crime_rate numeric:=.2;
  share numeric:=0; control_value numeric; population numeric; tax_value numeric; production_value numeric;
  trade_value numeric; recruit_limit numeric; weights jsonb;
begin
  select * into p from fauxlore.provinces where id=target_province and kind='land';
  if not found then return null; end if;
  select config into cfg from fauxlore.economy_parameters where singleton=true;
  select c.name into state_name from fauxlore.map_categories c where c.layer='states' and c.id=target_state;
  select category_id into owner_state from fauxlore.province_values where province_id=p.id and layer='states';
  select c.name into race_name from fauxlore.province_values v join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id where v.province_id=p.id and v.layer='races';
  select c.name into religion_name from fauxlore.province_values v join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id where v.province_id=p.id and v.layer='religions';
  select c.name into resource_name from fauxlore.province_values v join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id where v.province_id=p.id and v.layer='resources';
  if race_name is null or religion_name is null or state_name is null then return null; end if;
  if p.occupation is not null and (owner_state is null or lower(p.occupation)<>lower((select name from fauxlore.map_categories where layer='states' and id=owner_state))) then
    if lower(p.occupation)=lower(state_name) then share:=coalesce((cfg->>'occupationMultiplier')::numeric,.5); end if;
  elsif owner_state=target_state then share:=1;
  end if;
  if share=0 then return 0; end if;
  tax_mod:=nullif(cfg#>>array['provinceModifiers',p.province_type,'tax'],'')::numeric;
  prod_mod:=nullif(cfg#>>array['provinceModifiers',p.province_type,'production'],'')::numeric;
  trade_mod:=nullif(cfg#>>array['provinceModifiers',p.province_type,'trade'],'')::numeric;
  trade_base:=nullif(cfg#>>array['provinceModifiers',p.province_type,'tradeBase'],'')::numeric;
  trade_status_mod:=nullif(cfg#>>array['tradeStatusModifiers',coalesce(p.trade_status,'Отсутствует')],'')::numeric;
  if tax_mod is null or prod_mod is null or trade_mod is null or trade_base is null or trade_status_mod is null then return null; end if;
  select coalesce((r->>'value')::numeric,0),coalesce((r->>'production')::numeric,0) into resource_value,resource_prod
    from jsonb_array_elements(cfg->'resources') r where r->>'name'=resource_name limit 1;
  select coalesce(crime,.2) into crime_rate from fauxlore.state_profiles where state_id=owner_state;
  crime_rate:=coalesce(crime_rate,.2); population:=greatest(0,p.population)::numeric;
  control_value:=coalesce(p.control,100)::numeric/100;
  select coalesce(sum(gross),0) into tax_value from fauxlore.province_estate_gross_tax(p.id,target_state,share,cfg);
  tax_value:=(fauxlore.state_tax_breakdown(tax_value,coalesce((select crime from fauxlore.state_profiles where state_id=target_state),.2),coalesce((select corruption from fauxlore.state_profiles where state_id=target_state),.2),cfg)->>'net')::numeric;
  production_value:=round(population*resource_prod*prod_mod*control_value*(1-crime_rate)*share*fauxlore.group_status_effect(target_state,'race',(select category_id from fauxlore.province_values where province_id=p.id and layer='races'),'production')*fauxlore.group_status_effect(target_state,'religion',(select category_id from fauxlore.province_values where province_id=p.id and layer='religions'),'production')*greatest(0,coalesce(p.development,100))::numeric/100,0);
  trade_value:=round(trade_base*trade_mod*trade_status_mod*share*greatest(0,coalesce(p.development,100))::numeric/100,2);
  recruit_limit:=round(population/100
    *coalesce((cfg#>>array['recruitLimitModifiers',p.province_type])::numeric,0)
    *fauxlore.estate_recruit_modifier(p.province_type,p.population,cfg)
    *control_value*share*greatest(0,coalesce(p.development,100))::numeric/100,0);
  weights:=cfg->'provinceValueWeights';
  return round(((tax_value+production_value*resource_value)*coalesce((weights->>'gold')::numeric,0))
    +(trade_value*coalesce((weights->>'trade')::numeric,0))
    +(production_value*resource_value*coalesce((weights->>'production')::numeric,0))
    +(recruit_limit*coalesce((weights->>'recruits')::numeric,0))
    +(population*coalesce((weights->>'population')::numeric,0)*share),0);
end $function$;
