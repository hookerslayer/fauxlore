-- This script is appended to the draft migration and intentionally raises at
-- the end, so schema and fixture data are rolled back together.
create temporary table cost_test_calendar(year integer,turn integer);
insert into cost_test_calendar values(1452,1);
create trigger cost_test_port_charge before update on cost_test_calendar
  for each row execute function fauxlore.charge_port_upkeep_before_turn();
do $test$
declare uid uuid; state_value integer:=7; test_province integer:=2168; unit_value bigint;
  quote jsonb; result numeric; original_factor numeric; base_factor numeric; cash_before numeric; cash_after numeric; candidate record;
begin
  select a.auth_user_id into uid from fauxlore.accounts a
    join auth.users u on u.id=a.auth_user_id and u.email_confirmed_at is not null
    join auth.identities i on i.user_id=u.id and i.provider='google'
      and i.identity_data->>'email_verified'='true' and coalesce(i.identity_data->>'sub','')<>''
    where a.role='admin' limit 1;
  if uid is null then raise exception 'No verified admin available for rollback test'; end if;
  perform set_config('request.jwt.claim.sub',uid::text,true);
  update fauxlore.state_profiles set corruption=.02,crime=.02,recruits=1000 where state_id=state_value;
  select id into unit_value from fauxlore.military_unit_catalog where name='Копейщик' and active and state_id is null limit 1;
  select fauxlore.military_unit_cost_factor(state_value,unit_value,'hire') into base_factor;
  update fauxlore.state_profiles set corruption=.2,crime=.2 where state_id=state_value;
  if fauxlore.state_cost_multiplier(state_value)<>1.4 then raise exception 'Multiplier differs from 1.4'; end if;
  select fauxlore.military_unit_cost_factor(state_value,unit_value,'hire') into original_factor;
  if abs(original_factor-base_factor*1.4/1.04)>0.000001 then raise exception 'Military multiplier incorrect'; end if;
  quote:=public.garrison_api('quote_build',state_value,test_province,'{"kind":"fort","level":1}'::jsonb);
  if (quote->>'cost')::numeric<>14000 then raise exception 'Fort quote incorrect: %',quote; end if;
  quote:=public.garrison_api('quote_hire',state_value,test_province,jsonb_build_object('unit_id',unit_value,'quantity',10));
  result:=floor(10*(select hire_cost from fauxlore.military_unit_catalog where id=unit_value)*.7
    *greatest(0,1+fauxlore.state_permanent_modifier_total(state_value,array['garrison_hire_cost'],test_province,null))*1.4);
  if (quote->>'cost')::numeric<>result then raise exception 'Garrison quote incorrect: % / %',quote,result; end if;
  quote:=public.garrison_api('snapshot',state_value,null,'{}'::jsonb);
  if not exists(select 1 from jsonb_array_elements(quote->'provinces') p where (p->>'id')::integer=test_province and p ? 'troop_upkeep' and p ? 'fortification_upkeep') then
    raise exception 'Garrison snapshot missing upkeep'; end if;
  quote:=public.estate_social_api('snapshot',state_value,null);
  if (quote->>'cost')::numeric<>2800 then raise exception 'Social spending quote incorrect: %',quote; end if;
  select * into candidate from fauxlore.estate_investment_candidate(state_value,'Крестьяне',9999,1,100000000);
  if candidate.province_id is null or candidate.cost<>floor((1000+20*candidate.development_before)*1.4) then
    raise exception 'Estate investment price incorrect'; end if;
  perform fauxlore.militia_preview(state_value);
  perform fauxlore.militia_crown_upkeep(state_value);
  quote:=public.military_api('snapshot',state_value,'{}'::jsonb);
  if (quote->>'port_build_cost')::numeric<>14000 or (quote->>'port_upkeep_per_turn')::numeric<>280 then
    raise exception 'Port quote incorrect: %',quote; end if;
  insert into fauxlore.map_markers(province_id,x,y,type,name,state_id)
    select p.id,((p.bbox->>0)::numeric+(p.bbox->>2)::numeric)/2,
      ((p.bbox->>1)::numeric+(p.bbox->>3)::numeric)/2,'port','Тестовый порт',state_value
    from fauxlore.provinces p where p.kind='sea' and not exists(select 1 from fauxlore.map_markers m where m.type='port' and m.province_id=p.id) limit 1;
  if fauxlore.port_upkeep(state_value)<>280 then raise exception 'Port upkeep incorrect'; end if;
  select balance into cash_before from fauxlore.state_treasuries where state_id=state_value and estate='Корона';
  update cost_test_calendar set turn=turn+1;
  select balance into cash_after from fauxlore.state_treasuries where state_id=state_value and estate='Корона';
  if cash_before-cash_after<>280 then raise exception 'Port charge incorrect'; end if;
  raise exception 'INTENTIONAL_DRY_RUN_ROLLBACK';
end $test$;
