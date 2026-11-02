alter table fauxlore.admin_modifier_assignments add column target_scope text not null default 'state' check(target_scope in ('state','province','capital','cities','regions','race','religion'));
alter table fauxlore.admin_modifier_assignments add column target_group_id integer;
update fauxlore.admin_modifier_assignments set target_scope='province' where province_id is not null;
do $migration$
declare fn text; marker text; replacement text;
begin
 fn:=pg_get_functiondef('fauxlore.state_permanent_modifiers(integer)'::regprocedure);
 marker:=$old$case when a.province_id is null then 'Государство' else 'Провинция' end,'',7,a.province_id$old$;
 replacement:=$new$case a.target_scope when 'state' then 'Государство' when 'province' then 'Провинция' when 'capital' then 'Область:Столица' when 'cities' then 'Область:Города' when 'regions' then 'Область:Регионы' when 'race' then 'Область:Раса:'||a.target_group_id when 'religion' then 'Область:Религия:'||a.target_group_id end,'',7,a.province_id$new$;
 if position(marker in fn)=0 then raise exception 'modifier scope projection hook missing'; end if; execute replace(fn,marker,replacement);
 fn:=pg_get_functiondef('fauxlore.state_permanent_modifier_total(integer,text[],integer,text)'::regprocedure);
 marker:=$old$    if condition_value='Максимум' then continue; end if;$old$;
 replacement:=$new$    if scope_value like 'Область:%' then
      if target_province is null then continue; end if;
      if scope_value='Область:Столица' and province_row.province_type<>'Столичная' then continue; end if;
      if scope_value='Область:Города' and province_row.province_type not in ('Столичная','Городская') then continue; end if;
      if scope_value='Область:Регионы' and province_row.province_type<>'Регион' then continue; end if;
      if scope_value like 'Область:Раса:%' and not exists(select 1 from fauxlore.province_values v where v.province_id=target_province and v.layer='races' and v.category_id=substring(scope_value from length('Область:Раса:')+1)::integer) then continue; end if;
      if scope_value like 'Область:Религия:%' and not exists(select 1 from fauxlore.province_values v where v.province_id=target_province and v.layer='religions' and v.category_id=substring(scope_value from length('Область:Религия:')+1)::integer) then continue; end if;
    end if;
    if condition_value='Максимум' then continue; end if;$new$;
 if position(marker in fn)=0 then raise exception 'modifier scope calculation hook missing'; end if; execute replace(fn,marker,replacement);
 fn:=pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure);
 marker:=$old$    returning id into modifier_key;
    update fauxlore._settings$old$;
 replacement:=$new$    returning id into modifier_key;
    if coalesce(payload->>'scope','state') not in ('state','province','capital','cities','regions','race','religion') then raise sqlstate '22023' using message='Неизвестная область действия'; end if;
    if (payload->>'target_kind'='province') is distinct from (coalesce(payload->>'scope',case when province_key is not null then 'province' else 'state' end)='province') then raise sqlstate '22023' using message='Неверная область провинции'; end if;
    if coalesce(payload->>'scope','state') in ('capital','cities','regions','race','religion') and def.modifier_key not in ('tax_efficiency','population_growth','development','production','recruit_growth','recruit_limit','trade_influence','garrison_hire_cost','garrison_upkeep','garrison_limit','militia_coefficient') then raise sqlstate '22023' using message='Для этого эффекта область не поддерживается'; end if;
    if payload->>'scope' in ('race','religion') and not exists(select 1 from fauxlore.province_values owner join fauxlore.province_values grp on grp.province_id=owner.province_id where owner.layer='states' and owner.category_id=state_key and grp.layer=case payload->>'scope' when 'race' then 'races' else 'religions' end and grp.category_id=nullif(payload->>'group_id','')::integer) then raise sqlstate '22023' using message='Раса или религия отсутствует в государстве'; end if;
    update fauxlore.admin_modifier_assignments set target_scope=coalesce(payload->>'scope',case when province_key is null then 'state' else 'province' end),target_group_id=case when payload->>'scope' in ('race','religion') then (payload->>'group_id')::integer else null end where id=modifier_key;
    update fauxlore._settings$new$;
 if position(marker in fn)=0 then raise exception 'modifier assignment scope hook missing'; end if; execute replace(fn,marker,replacement);
end $migration$;
notify pgrst,'reload schema';
