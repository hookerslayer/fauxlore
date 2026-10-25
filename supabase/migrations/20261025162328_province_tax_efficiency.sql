-- Replace province-type tax multipliers with collection efficiency.
-- Tax development is a penalty only; development above 100 has no tax bonus.
create or replace function fauxlore.province_tax_efficiency(province_type text)
returns numeric language sql immutable set search_path='' as $$
select case province_type
  when 'Столичная' then .7::numeric
  when 'Городская' then .6::numeric
  when 'Регион' then .3::numeric
  else null::numeric
end
$$;
revoke all on function fauxlore.province_tax_efficiency(text) from public,anon,authenticated;

create or replace function fauxlore.state_tax_efficiency(target_state integer)
returns numeric language sql stable security definer set search_path='' as $$
with owned as (
  select p.population,fauxlore.province_tax_efficiency(p.province_type) efficiency
  from fauxlore.provinces p
  join fauxlore.province_values v on v.province_id=p.id and v.layer='states' and v.category_id=target_state
  where p.kind='land'
)
select case when count(*)=0 then null
  when coalesce(sum(population),0)>0 then sum(population*efficiency)/sum(population)
  else avg(efficiency)
end
from owned
$$;
revoke all on function fauxlore.state_tax_efficiency(integer) from public,anon,authenticated;

create or replace function fauxlore.province_estate_gross_tax(target_province integer,target_state integer,share numeric,cfg jsonb)
returns table(estate text,population bigint,gross numeric)
language sql stable security invoker set search_path='' as $$
select e.estate,e.population,
  floor(e.population::numeric*fauxlore.estate_tax_rate(target_state,e.estate,cfg)
    *greatest(0,least(100,coalesce(p.development,100)))::numeric/100
    *greatest(0,least(1,share)))
from fauxlore.provinces p cross join lateral fauxlore.estate_population(p.province_type,p.population) e
where p.id=target_province and p.kind='land'
$$;
revoke all on function fauxlore.province_estate_gross_tax(integer,integer,numeric,jsonb) from public,anon,authenticated;

-- Keep the historic config keys for compatibility, but neutralize the retired
-- multipliers so no legacy consumer can manufacture tax income by province type.
update fauxlore.economy_parameters
set config=jsonb_set(jsonb_set(jsonb_set(config,'{provinceModifiers,Столичная,tax}','1'::jsonb),
  '{provinceModifiers,Городская,tax}','1'::jsonb),'{provinceModifiers,Регион,tax}','1'::jsonb)
where singleton=true;

do $migration$
declare fn text; old_fragment text; new_fragment text; marker text;
begin
  fn:=pg_get_functiondef('fauxlore.turn_api(text,text,jsonb,uuid)'::regprocedure);
  old_fragment:=$old$if nullif(cfg#>>array['provinceModifiers',province_row.province_type,'tax'],'') is null then
      raise sqlstate '22023' using message='Не задан налоговый коэффициент провинции '||province_row.id; end if;$old$;
  if position(old_fragment in fn)=0 then raise exception 'Turn tax multiplier validation fragment not found'; end if;
  fn:=replace(fn,old_fragment,'');
  marker:='tax_net:=(tax_effects->>''net'')::numeric;';
  if position(marker in fn)=0 then raise exception 'Turn tax collection insertion point not found'; end if;
  new_fragment:='tax_net:=floor((tax_effects->>''net'')::numeric*fauxlore.province_tax_efficiency(province_row.province_type)'||
    '*greatest(0,least(100,coalesce(province_row.control,100)))::numeric/100);';
  execute replace(fn,marker,new_fragment);

  fn:=pg_get_functiondef('fauxlore.province_value_for_state(integer,integer)'::regprocedure);
  marker:='  tax_value:=(fauxlore.state_tax_breakdown(tax_value,';
  if position(marker in fn)=0 then raise exception 'Province appraisal tax insertion point not found'; end if;
  fn:=replace(fn,'if tax_mod is null or prod_mod is null','if prod_mod is null');
  marker:='tax_value:=(fauxlore.state_tax_breakdown(tax_value,coalesce((select crime from fauxlore.state_profiles where state_id=target_state),.2),coalesce((select corruption from fauxlore.state_profiles where state_id=target_state),.2),cfg)->>''net'')::numeric;';
  if position(marker in fn)=0 then raise exception 'Province appraisal net tax expression not found'; end if;
  execute replace(fn,marker,marker||chr(10)||
    '  tax_value:=floor(tax_value*fauxlore.province_tax_efficiency(p.province_type)*greatest(0,least(100,coalesce(p.control,100)))::numeric/100);');

  fn:=pg_get_functiondef('fauxlore.state_indicators(integer)'::regprocedure);
  marker:='''state_effect_coefficients'',cfg.config->''stateEffects'')';
  if position(marker in fn)=0 then raise exception 'State indicator tax efficiency insertion point not found'; end if;
  execute replace(fn,marker,'''tax_efficiency'',fauxlore.state_tax_efficiency(target_state),''state_effect_coefficients'',cfg.config->''stateEffects'')');
end
$migration$;

notify pgrst,'reload schema';
