do $$
declare definition text; old_text text; new_text text;
begin
 definition:=pg_get_functiondef('public.estate_fiscal_api(text,integer,jsonb)'::regprocedure);
 old_text:=$old$insert into fauxlore.state_budget_ledger(state_id,estate,year,turn,kind,cash_delta,debt_delta,details)
     values(target_state,'Корона',cal.year,cal.turn,'estate_loyalty_investment',-amount_value,0,
       jsonb_build_object('estate',estate_name,'amount',amount_value)),
       (target_state,estate_name,cal.year,cal.turn,'estate_loyalty_investment',amount_value,0,
       jsonb_build_object('direction','received','loyalty_bonus',bonus_value));$old$;
 new_text:=$new$insert into fauxlore.state_budget_ledger(state_id,estate,year,turn,kind,cash_delta,debt_delta,details)
     values(target_state,'Корона',cal.year,cal.turn,'estate_loyalty_investment',-amount_value,0,
       jsonb_build_object('estate',estate_name,'amount',amount_value));$new$;
 if position(old_text in definition)=0 then raise exception 'Investment ledger source marker missing'; end if;
 definition:=replace(definition,old_text,new_text);
 old_text:=$old$insert into fauxlore.state_budget_ledger(state_id,estate,year,turn,kind,cash_delta,debt_delta,details)
     values(target_state,estate_name,cal.year,cal.turn,'estate_military_tax',-tax_value,0,
       jsonb_build_object('war_id',war.id)),
       (target_state,'Корона',cal.year,cal.turn,'estate_military_tax',tax_value,0,
       jsonb_build_object('estate',estate_name,'war_id',war.id));$old$;
 new_text:=$new$insert into fauxlore.state_budget_ledger(state_id,estate,year,turn,kind,cash_delta,debt_delta,details)
     values(target_state,'Корона',cal.year,cal.turn,'estate_military_tax',tax_value,0,
       jsonb_build_object('estate',estate_name,'war_id',war.id));$new$;
 if position(old_text in definition)=0 then raise exception 'Military tax ledger source marker missing'; end if;
 execute replace(definition,old_text,new_text);
end $$;
