insert into fauxlore.permanent_modifier_definitions(source_kind,source_key,modifier_key,effect,value,unit,scope,condition_text) values
 ('constructor','Назначение','loan_nobility_rate','Процентная ставка займов у Знати',0,'п.п.','Государство',''),
 ('constructor','Назначение','loan_clergy_rate','Процентная ставка займов у Духовенства',0,'п.п.','Государство',''),
 ('constructor','Назначение','loan_burgher_rate','Процентная ставка займов у Горожан',0,'п.п.','Государство',''),
 ('constructor','Назначение','loan_peasant_rate','Процентная ставка займов у Крестьян',0,'п.п.','Государство','');
alter table fauxlore.state_estate_loans drop constraint state_estate_loans_interest_rate_check;
alter table fauxlore.state_estate_loans add constraint state_estate_loans_interest_rate_check check(interest_rate between 0 and 999.99);
create function fauxlore.estate_loan_interest(target_state integer,lender text) returns numeric language sql stable security definer set search_path='' as $$
 select round(greatest(0,least(999.99,5+100*fauxlore.state_permanent_modifier_total(target_state,array[case lender when 'Знать' then 'loan_nobility_rate' when 'Духовенство' then 'loan_clergy_rate' when 'Горожане' then 'loan_burgher_rate' when 'Крестьяне' then 'loan_peasant_rate' end],null,null))),2)
$$;
revoke all on function fauxlore.estate_loan_interest(integer,text) from public,anon,authenticated;
do $migration$
declare fn text; marker text; replacement text;
begin
 fn:=pg_get_functiondef('fauxlore.state_estate_loans_api(text,text,jsonb,uuid)'::regprocedure);
 marker:=$old$'state_id',state_key,'rate',5,'term_turns',5,$old$;
 replacement:=$new$'state_id',state_key,'rate',5,'rates',jsonb_build_object('Знать',fauxlore.estate_loan_interest(state_key,'Знать'),'Духовенство',fauxlore.estate_loan_interest(state_key,'Духовенство'),'Горожане',fauxlore.estate_loan_interest(state_key,'Горожане'),'Крестьяне',fauxlore.estate_loan_interest(state_key,'Крестьяне')),'term_turns',5,$new$;
 if position(marker in fn)=0 then raise exception 'loan rates snapshot hook missing'; end if; fn:=replace(fn,marker,replacement);
 marker:=$old$insert into fauxlore.state_estate_loans(state_id,lender,principal,total_due,due_turn,created_year,created_turn,created_by)$old$;
 replacement:=$new$insert into fauxlore.state_estate_loans(state_id,lender,principal,interest_rate,total_due,due_turn,created_year,created_turn,created_by)$new$;
 if position(marker in fn)=0 then raise exception 'loan insert hook missing'; end if; fn:=replace(fn,marker,replacement);
 marker:=$old$values(state_key,lender_value,amount_value,floor(amount_value*1.05),cal.turn+5,cal.year,cal.turn,actor.id)$old$;
 replacement:=$new$values(state_key,lender_value,amount_value,fauxlore.estate_loan_interest(state_key,lender_value),floor(amount_value*(1+fauxlore.estate_loan_interest(state_key,lender_value)/100)),cal.turn+5,cal.year,cal.turn,actor.id)$new$;
 if position(marker in fn)=0 then raise exception 'loan amount hook missing'; end if; execute replace(fn,marker,replacement);
end $migration$;
notify pgrst,'reload schema';
