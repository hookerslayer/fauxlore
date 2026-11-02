do $migration$
declare fn text; marker text;
begin
 fn:=pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure);
 marker:=$old$case when def.modifier_key='population_growth' then 'Прирост населения' else def.effect end,value_key,def.unit,$old$;
 if position(marker in fn)=0 then raise exception 'modifier display hook missing';end if;
 fn:=replace(fn,marker,$new$case def.modifier_key when 'population_growth' then 'Прирост населения' when 'development' then 'Постоянное изменение развития' when 'internal_trade_income' then 'Внутренняя торговля' when 'trade_zone_income' then 'Доход от торговой зоны' when 'garrison_hire_cost' then 'Стоимость найма в гарнизон' when 'garrison_upkeep' then 'Стоимость содержания гарнизонов' when 'fortification_upkeep' then 'Содержание укреплений' when 'militia_coefficient' then 'Коэффициент сбора ополчения' when 'cavalry_hire_cost' then 'Стоимость кавалерии' when 'fleet_hire_cost' then 'Стоимость флота' else def.effect end,value_key,case when def.modifier_key in ('production','internal_trade_income','trade_zone_income','recruit_growth','recruit_limit','trade_influence','garrison_hire_cost','garrison_upkeep') then 'п.п.' else def.unit end,$new$);execute fn;
end $migration$;
