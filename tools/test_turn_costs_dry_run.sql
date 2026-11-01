-- Run only inside the migration transaction; deliberately abort at the end.
do $test$
declare uid uuid; cal fauxlore.game_calendar; response jsonb; initial_cash numeric; charge numeric; after_cash numeric;
begin
  -- Acquire restoration locks up front and abort immediately if another
  -- transaction is using these rows, rather than deadlocking during rollback.
  lock table fauxlore.state_profiles,fauxlore.state_group_politics,fauxlore.state_characters,
    fauxlore.state_succession_events,fauxlore.state_birth_events,fauxlore.notifications,
    fauxlore.state_treasuries,fauxlore.state_treasury_debts,fauxlore.state_budget_ledger,
    fauxlore.trade_settlements,fauxlore.trade_market_settlements,fauxlore.trade_interzone_settlements,
    fauxlore.trade_state_resource_turns,fauxlore.trade_zone_resource_turns,fauxlore.trade_zone_income_turns,
    fauxlore.turn_economy_reports,fauxlore.game_calendar,fauxlore.military_formations,
    fauxlore.military_formation_units,fauxlore.military_movement_orders,fauxlore.military_battles,
    fauxlore.province_weather,fauxlore.provinces,fauxlore.province_values,fauxlore.map_markers,
    fauxlore.military_port_projects,fauxlore.military_port_builds,fauxlore.garrison_sites,
    fauxlore.garrison_units,fauxlore.garrison_projects,fauxlore.garrison_charges,
    fauxlore.estate_investment_events,fauxlore.estate_social_actions,fauxlore.estate_fiscal_events,
    fauxlore.state_estate_loans,fauxlore.state_estate_loan_events,fauxlore.military_sieges
    in access exclusive mode nowait;
  select a.auth_user_id into uid from fauxlore.accounts a
    join auth.users u on u.id=a.auth_user_id and u.email_confirmed_at is not null
    join auth.identities i on i.user_id=u.id and i.provider='google'
      and i.identity_data->>'email_verified'='true' and coalesce(i.identity_data->>'sub','')<>''
    where a.role='admin' limit 1;
  if uid is null then raise exception 'No verified admin available for rollback test'; end if;
  perform set_config('request.jwt.claim.sub',uid::text,true);
  if exists(select 1 from fauxlore.turn_test_snapshot) then raise exception 'Existing test turn is active'; end if;
  -- The existing full market calculation exceeds the hosted SQL timeout.
  -- Use one resource in this rolled-back fixture to exercise every turn phase.
  update fauxlore.economy_parameters set config=jsonb_set(config,'{resources}',
    (select jsonb_agg(r) from jsonb_array_elements(config->'resources') r where r->>'name'='Зерно'))
    where singleton;
  delete from fauxlore.province_values where layer='trade' and category_id<>(
    select min(category_id) from fauxlore.province_values where layer='trade');
  insert into fauxlore.map_markers(province_id,x,y,type,name,state_id)
    select p.id,((p.bbox->>0)::numeric+(p.bbox->>2)::numeric)/2,
      ((p.bbox->>1)::numeric+(p.bbox->>3)::numeric)/2,'port','Тестовый порт',7
    from fauxlore.provinces p where p.kind='sea' and not exists(select 1 from fauxlore.map_markers m where m.type='port' and m.province_id=p.id) limit 1;
  select * into cal from fauxlore.game_calendar where singleton;
  select balance into initial_cash from fauxlore.state_treasuries where state_id=7 and estate='Корона';
  response:=fauxlore.test_turn_api('admin/turn/test/advance','POST',jsonb_build_object('expected_year',cal.year,'expected_turn',cal.turn),gen_random_uuid());
  select -cash_delta into charge from fauxlore.state_budget_ledger where state_id=7 and year=cal.year and turn=cal.turn and kind='port_upkeep' order by id desc limit 1;
  if charge is null or charge<200 then raise exception 'Port upkeep was not charged: %',charge; end if;
  response:=fauxlore.test_turn_api('admin/turn/test/rollback','POST','{}'::jsonb,gen_random_uuid());
  select balance into after_cash from fauxlore.state_treasuries where state_id=7 and estate='Корона';
  if after_cash is distinct from initial_cash then raise exception 'Test turn did not restore the crown balance'; end if;
  if exists(select 1 from fauxlore.state_budget_ledger where state_id=7 and year=cal.year and turn=cal.turn and kind='port_upkeep') then
    raise exception 'Test turn did not restore the port ledger'; end if;
  raise exception 'INTENTIONAL_DRY_RUN_ROLLBACK';
end $test$;
