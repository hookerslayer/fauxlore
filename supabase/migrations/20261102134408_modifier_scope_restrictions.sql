do $migration$
declare fn text; marker text;
begin
 fn:=pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure);
 marker:=$old$if payload ? 'definition_key' and payload->>'definition_key' is distinct from def.modifier_key then$old$;
 if position(marker in fn)=0 then raise exception 'modifier scope identity hook missing';end if;
 fn:=replace(fn,marker,$new$if province_key is not null and def.modifier_key in ('crime_pp','corruption_pp','development_limit_flat','state_stability_flat','nobility_loyalty','clergy_loyalty','burgher_loyalty','peasant_loyalty','nobility_influence_pp','clergy_influence_pp','burgher_influence_pp','peasant_influence_pp','nobility_stabilization','clergy_stabilization','burgher_stabilization','peasant_stabilization','race_human_loyalty','race_dwarf_loyalty','race_elf_loyalty','race_halfelf_loyalty','race_beast_loyalty','internal_trade_income','trade_zone_income','loan_nobility_rate','loan_clergy_rate','loan_burgher_rate','loan_peasant_rate','military_tradition_pp','naval_tradition_pp','leader_limit_flat','leader_prestige_cost_flat','mercenary_hire_cost','mercenary_upkeep','infantry_hire_cost','cavalry_hire_cost','siege_hire_cost','artillery_hire_cost','fleet_hire_cost','infantry_upkeep','cavalry_upkeep','siege_upkeep','artillery_upkeep','fleet_upkeep') then
  raise sqlstate '22023' using message='Этот модификатор назначается государству';end if;
 if payload ? 'definition_key' and payload->>'definition_key' is distinct from def.modifier_key then$new$);execute fn;
end $migration$;
