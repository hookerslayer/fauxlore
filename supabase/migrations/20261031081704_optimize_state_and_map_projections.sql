-- Compute per-province values and per-state tax rates once per snapshot.
-- The temporary baseline makes the migration atomic if results change.
set transaction isolation level repeatable read;
set local statement_timeout = '90s';
create temporary table state_projection_before on commit drop as
select state_id, fauxlore.state_indicators(state_id) indicators from fauxlore.state_profiles;
create temporary table map_projection_before on commit drop as
select md5(fauxlore.map_payload_unfiltered()::text) digest;

do $migration$
declare definition text; old_part text; new_part text;
begin
 definition:=pg_get_functiondef('fauxlore.state_indicators_before_urbanization(integer)'::regprocedure);
 old_part:='), estates as (';
 if position(old_part in definition)=0 then raise exception 'state indicators: estates marker missing'; end if;
 new_part:='), relevant_values as materialized ('||chr(10)||
   '  select p.*,fauxlore.province_value_for_state(p.id,target_state) cached_state_value from relevant p where p.share>0'||chr(10)||
   '), estates as (';
 definition:=replace(definition,old_part,new_part);
 old_part:='sum(fauxlore.province_value_for_state(p.id,target_state)*ep.population';
 if position(old_part in definition)=0 then raise exception 'state indicators: value marker missing'; end if;
 definition:=replace(definition,old_part,'sum(p.cached_state_value*ep.population');
 old_part:='left join relevant p on p.share>0';
 if position(old_part in definition)=0 then raise exception 'state indicators: province join missing'; end if;
 definition:=replace(definition,old_part,'left join relevant_values p on true');
 execute definition;

 definition:=pg_get_functiondef('fauxlore.state_indicators(integer)'::regprocedure);
 old_part:='select min(fauxlore.effective_province_tax_efficiency(target_state,p.id)) min_rate,'||chr(10)||
 '         max(fauxlore.effective_province_tax_efficiency(target_state,p.id)) max_rate'||chr(10)||
 '  from fauxlore.provinces p'||chr(10)||
 '  join fauxlore.province_values owner on owner.province_id=p.id and owner.layer=''states'' and owner.category_id=target_state'||chr(10)||
 '  where p.kind=''land''';
 if position(old_part in definition)=0 then raise exception 'state indicators: tax rate marker missing'; end if;
 new_part:='with province_rates as materialized ('||chr(10)||
 '  select fauxlore.effective_province_tax_efficiency(target_state,p.id) rate'||chr(10)||
 '  from fauxlore.provinces p join fauxlore.province_values owner on owner.province_id=p.id and owner.layer=''states'' and owner.category_id=target_state'||chr(10)||
 '  where p.kind=''land'') select min(rate) min_rate,max(rate) max_rate from province_rates';
 definition:=replace(definition,old_part,new_part);
 execute definition;

 definition:=pg_get_functiondef('fauxlore.map_payload_unfiltered()'::regprocedure);
 old_part:='with s as (select';
 if position(old_part in definition)=0 then raise exception 'map payload: CTE marker missing'; end if;
 new_part:='with state_tax_rates as materialized (select c.id,fauxlore.state_estate_tax_rates_json(c.id) rates from fauxlore.map_categories c where c.layer=''states''),'||chr(10)||'s as (select';
 definition:=replace(definition,old_part,new_part);
 old_part:='fauxlore.state_estate_tax_rates_json(c.id)';
 -- Preserve the single computation in the materialized CTE, replace the three consumers.
 if (length(definition)-length(replace(definition,old_part,'')))/length(old_part)<>4 then raise exception 'map payload: tax-rate reference count changed'; end if;
 definition:=replace(definition,old_part,'(select r.rates from state_tax_rates r where r.id=c.id)');
 definition:=replace(definition,'select c.id,(select r.rates from state_tax_rates r where r.id=c.id) rates from fauxlore.map_categories c','select c.id,fauxlore.state_estate_tax_rates_json(c.id) rates from fauxlore.map_categories c');
 execute definition;
end
$migration$;

do $verify$
declare mismatches integer;
begin
 select count(*) into mismatches from state_projection_before b
 where b.indicators is distinct from fauxlore.state_indicators(b.state_id);
 if mismatches<>0 then raise exception 'State indicator parity failed for % states',mismatches; end if;
 if (select digest from map_projection_before) is distinct from md5(fauxlore.map_payload_unfiltered()::text) then
  raise exception 'Map snapshot parity failed';
 end if;
end
$verify$;
notify pgrst,'reload schema';
