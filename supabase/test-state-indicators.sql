-- Run as the database operator. Every test and fixture is inside ROLLBACK.
-- No production turn is committed. Requires an existing verified admin.
begin;
set local statement_timeout = '90s';
create temporary table indicator_test_results(scenario text, states integer, local_flows integer, interzone_flows integer) on commit drop;
do $$
declare
  baseline jsonb; body jsonb; outcome jsonb; after_turn jsonb;
  command_id uuid; scenario text; item jsonb; expected_deficit numeric;
  expected_required numeric; delta numeric; balance numeric; resource record;
  sid integer; population_value numeric; original_config jsonb;
  yr integer; trn integer; food_count integer; opening_indicators jsonb; step_value integer; corruption_step_value numeric; tax_line jsonb;
begin
  if exists(select 1 from fauxlore.turn_test_snapshot) then
    raise exception 'An existing test turn must be resolved before running this suite';
  end if;
  perform set_config('request.jwt.claim.sub',(select auth_user_id::text from fauxlore.accounts where role='admin' and auth_user_id is not null limit 1),true);
  perform fauxlore.current_account();
  select config into original_config from fauxlore.economy_parameters where singleton;
  create temporary table food_before(state_id integer, name text, balance numeric, required numeric) on commit drop;
  foreach scenario in array array['current markets','zero consumption','no food at crime ceiling','abundant food','crime floor'] loop
    update fauxlore.economy_parameters set config=original_config where singleton;
    if scenario in ('zero consumption','crime floor') then
      if scenario='crime floor' then
        for sid in select state_id from fauxlore.state_profiles loop perform fauxlore.ensure_state_group_politics(sid); end loop;
        update fauxlore.state_group_politics set loyalty=1;
        update fauxlore.state_profiles set crime=.02,corruption=.02;
        update fauxlore.provinces set belonging='Корона' where kind='land';
      end if;
      update fauxlore.economy_parameters set config=jsonb_set(config,'{resources}',
        (select jsonb_agg(r||jsonb_build_object('consumption',0)) from jsonb_array_elements(config->'resources') r)) where singleton;
    elsif scenario='no food at crime ceiling' then
      update fauxlore.state_profiles set crime=1,corruption=.9;
    elsif scenario='abundant food' then
      update fauxlore.state_profiles set crime=.2,corruption=.2;
      -- Give every populated land province grain; restore this fixture with
      -- the outer transaction rollback (province data is not a turn mutation).
      update fauxlore.province_values v set category_id=(select id from fauxlore.map_categories where layer='resources' and name='Зерно')
        from fauxlore.provinces p where p.id=v.province_id and p.kind='land' and v.layer='resources';
      update fauxlore.economy_parameters set config=jsonb_set(config,'{resources}',
        (select jsonb_agg(case when r->>'name'='Зерно' then r||jsonb_build_object('production',10000)
          when r->>'name' in ('Морепродукты','Животноводство','Фрукты') then r||jsonb_build_object('consumption',0) else r end)
          from jsonb_array_elements(config->'resources') r)) where singleton;
    end if;
    truncate food_before;
    for sid in select state_id from fauxlore.state_profiles loop
      select coalesce(sum(p.population),0) into population_value from fauxlore.provinces p
        join fauxlore.province_values v on v.province_id=p.id and v.layer='states' and v.category_id=sid where p.kind='land';
      for resource in select r->>'name' name,(r->>'consumption')::numeric consumption
        from fauxlore.economy_parameters cross join lateral jsonb_array_elements(config->'resources') r
        where singleton and r->>'name' in ('Зерно','Морепродукты','Животноводство','Фрукты') loop
        insert into food_before values(sid,resource.name,fauxlore.trade_resource_surplus(sid,resource.name),ceil(population_value/10*resource.consumption));
      end loop;
    end loop;
    baseline:=fauxlore.turn_snapshot_payload();
    select year,turn into yr,trn from fauxlore.game_calendar where singleton;
    body:=jsonb_build_object('expected_year',yr,'expected_turn',trn);
    command_id:=gen_random_uuid();
    outcome:=fauxlore.test_turn_api('admin/turn/test/advance','POST',body,command_id);
    after_turn:=fauxlore.turn_snapshot_payload();
    if fauxlore.turn_api('admin/turn/advance','POST',body,command_id) is distinct from outcome-array['test_mode','rollback_available']
      or fauxlore.turn_snapshot_payload() is distinct from after_turn then raise exception 'Repeated turn changed state'; end if;
    for item in select r from fauxlore.turn_economy_reports cross join lateral jsonb_array_elements(report) r where year=yr and turn=trn loop
      sid:=(item->>'id')::integer; expected_deficit:=0; expected_required:=0;
      for resource in select * from food_before where state_id=sid loop
        -- Independently reconcile the opening surplus with all posted flows.
        select coalesce(sum(amount),0) into delta from (
          select case when (case when s.direction='forward' then a.from_state_id else a.to_state_id end)=sid then -s.sent else s.received end amount
          from fauxlore.trade_settlements s join fauxlore.trade_agreements a on a.id=s.agreement_id
          where s.year=yr and s.turn=trn and s.item_kind='resource' and s.item_name=resource.name and sid in (a.from_state_id,a.to_state_id)
          union all select case when buyer_state_id=sid then quantity else -quantity end from fauxlore.trade_market_settlements
            where year=yr and turn=trn and resource_name=resource.name and sid in (buyer_state_id,seller_state_id)
          union all select case when buyer_state_id=sid then quantity else -quantity end from fauxlore.trade_interzone_settlements
            where year=yr and turn=trn and resource_name=resource.name and sid in (buyer_state_id,seller_state_id)
        ) flows;
        balance:=resource.balance+delta;
        expected_required:=expected_required+resource.required;
        if resource.required>0 then expected_deficit:=expected_deficit+greatest(0,-balance); end if;
      end loop;
      if (item->>'food_required_units')::numeric<>expected_required or (item->>'food_deficit_units')::numeric<>expected_deficit
        or (item->>'food_coverage_pct')::numeric<>(case when expected_required=0 then 100 else greatest(0,least(100,round((1-expected_deficit/expected_required)*100,2))) end)
        then raise exception 'Food reconciliation failed for state %, scenario %',sid,scenario; end if;
      if (item->>'crime_rate_at_turn_start_pct')::numeric<>(select (r->>'crime')::numeric*100 from jsonb_array_elements(baseline->'state_profiles') r where (r->>'state_id')::integer=sid)
        then raise exception 'Opening crime mismatch'; end if;
      opening_indicators:=item->'indicators_at_turn_start';
      if opening_indicators is null then raise exception 'Missing opening indicators'; end if;
      step_value:=(fauxlore.crime_step((item->>'food_coverage_pct')::numeric,(opening_indicators->>'stability')::numeric)->>'crime_step_pp')::integer;
      if (item->>'crime_rate_after_pct')::numeric<>greatest(2,least(100,(item->>'crime_rate_at_turn_start_pct')::numeric+step_value))
        or (item->>'crime_rate_after_pct')::numeric<>(select crime*100 from fauxlore.state_profiles where state_id=sid)
        or (item->>'crime_change_pp')::numeric<>(item->>'crime_rate_after_pct')::numeric-(item->>'crime_rate_at_turn_start_pct')::numeric then
        raise exception 'Crime transition mismatch';
      end if;
      if scenario='abundant food' and (item->>'food_coverage_pct')::numeric<>100 then raise exception 'Abundant fixture does not cover all food'; end if;
      if scenario='crime floor' and ((item->>'crime_step_pp')::integer<>-1 or (item->>'crime_rate_after_pct')::numeric<>2) then raise exception 'Crime floor mismatch'; end if;
      corruption_step_value:=(fauxlore.corruption_step((opening_indicators->>'total_development')::numeric,(opening_indicators->>'development_limit')::numeric,
        (opening_indicators->>'stability')::numeric,(select config from fauxlore.economy_parameters where singleton))->>'corruption_step_pp')::numeric;
      if (item->>'corruption_rate_after_pct')::numeric<>round(greatest(2,least(90,(item->>'corruption_rate_at_turn_start_pct')::numeric+corruption_step_value)),5)
        or (item->>'corruption_rate_after_pct')::numeric<>(select corruption*100 from fauxlore.state_profiles where state_id=sid) then raise exception 'Corruption transition mismatch'; end if;
      if scenario='crime floor' and (item->>'corruption_rate_after_pct')::numeric<>2 then raise exception 'Corruption floor mismatch'; end if;
      if scenario='no food at crime ceiling' and (item->>'corruption_rate_after_pct')::numeric<>90 then raise exception 'Corruption ceiling mismatch'; end if;
      if (item->>'net_taxes')::numeric<>(item->>'crown_taxes')::numeric+(item->>'estate_taxes')::numeric
        or (item->>'gross_taxes')::numeric<>(item->>'net_taxes')::numeric+(item->>'corruption_tax_loss')::numeric+(item->>'crime_tax_loss')::numeric then raise exception 'State tax invariant failed'; end if;
      for tax_line in select value from jsonb_array_elements(item->'tax_details') loop
        if (tax_line->>'net')::numeric<>(tax_line->>'crown')::numeric+(tax_line->>'estate')::numeric
          or (tax_line->>'net')::numeric<>(tax_line->>'gross')::numeric-(tax_line->>'corruption_loss')::numeric-(tax_line->>'crime_loss')::numeric then raise exception 'Province tax invariant failed'; end if;
        if fauxlore.state_tax_breakdown((tax_line->>'gross')::numeric,(item->>'crime_rate_at_turn_start_pct')::numeric/100,(item->>'corruption_rate_at_turn_start_pct')::numeric/100,
          (select config from fauxlore.economy_parameters where singleton))->>'net' is distinct from tax_line->>'net' then raise exception 'Taxes used closing rates'; end if;
      end loop;
    end loop;
    insert into indicator_test_results select scenario,jsonb_array_length((select report from fauxlore.turn_economy_reports where year=yr and turn=trn)),
      (select count(*) from fauxlore.trade_market_settlements where year=yr and turn=trn),
      (select count(*) from fauxlore.trade_interzone_settlements where year=yr and turn=trn);
    perform fauxlore.test_turn_api('admin/turn/test/rollback','POST','{}',gen_random_uuid());
    if fauxlore.turn_snapshot_payload() is distinct from baseline then raise exception 'Rollback did not restore snapshot'; end if;
    if exists(select 1 from fauxlore.operations where request_id=command_id) then raise exception 'Operation survived rollback'; end if;
  end loop;
end $$;
select * from indicator_test_results;
rollback;
