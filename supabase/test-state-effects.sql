-- Operator-only regression checks; fixtures and administrative edits roll back.
begin;
do $$
declare cfg jsonb; row_value record; actual jsonb; sid integer; rid uuid; response jsonb; old_history bigint; new_cfg jsonb;
begin
  select config into cfg from fauxlore.economy_parameters where singleton;
  for row_value in select * from (values
    (1000,1000,.6,0::numeric),(1001,1000,.6,.001),(1500,1000,.6,.5),(4000,1000,.2,3),
    (101,100,.6,.01),(150,100,.6,.5),(100001,100000,.6,.00001),(0,0,.6,0),(1,0,.6,3),
    (1000,1000,.75,-1),(1000,1000,.5,0),(1000,1000,.25,1),(1000,1000,.2499,2)
  ) t(development,lim,stability,expected) loop
    actual:=fauxlore.corruption_step(row_value.development,row_value.lim,row_value.stability,cfg);
    if (actual->>'corruption_step_pp')::numeric<>row_value.expected then raise exception 'Corruption boundary failed: %',row_value; end if;
  end loop;
  for row_value in select * from (values (100::numeric,.2::numeric,.2::numeric,76::numeric),(.03,.2,.2,.02),(100,1,.9,7.5),(0,1,.9,0)) t(gross,crime,corruption,net) loop
    actual:=fauxlore.state_tax_breakdown(row_value.gross,row_value.crime,row_value.corruption,cfg);
    if (actual->>'net')::numeric<>row_value.net or (actual->>'gross')::numeric<>(actual->>'net')::numeric+(actual->>'crime_loss')::numeric+(actual->>'corruption_loss')::numeric
      then raise exception 'Tax rounding failed: %',row_value; end if;
  end loop;
  select min(state_id) into sid from fauxlore.state_profiles;
  perform fauxlore.ensure_state_group_politics(sid);
  update fauxlore.state_profiles set corruption=.9 where state_id=sid;
  actual:=fauxlore.state_indicators(sid);
  if (actual->>'corruption_loyalty_bonus')::numeric<>.15 then raise exception 'Loyalty cap failed'; end if;
  if fauxlore.state_indicators(sid)<>actual then raise exception 'Loyalty accumulated on read'; end if;
  -- Simulate a very small final corruption update and verify stored precision.
  update fauxlore.state_profiles set corruption=.20001 where state_id=sid;
  if (select corruption from fauxlore.state_profiles where state_id=sid)<>.20001 then raise exception 'Small overload step was lost'; end if;
  perform set_config('request.jwt.claim.sub',(select auth_user_id::text from fauxlore.accounts where role='admin' and auth_user_id is not null limit 1),true);
  select count(*) into old_history from fauxlore.economy_parameter_history;
  new_cfg:=jsonb_set(cfg,'{stateEffects,crimeTaxPenalty}','0.3');rid:=gen_random_uuid();
  response:=public.fauxlore_api('admin/economy/config','PATCH',jsonb_build_object('config',new_cfg),rid);
  if public.fauxlore_api('admin/economy/config','PATCH',jsonb_build_object('config',new_cfg),rid)<>response then raise exception 'Config retry mismatch'; end if;
  if (select count(*) from fauxlore.economy_parameter_history)<>old_history+1 then raise exception 'Config audit/retry failed'; end if;
  if (fauxlore.state_tax_breakdown(100,.2,.2,new_cfg)->>'net')::numeric<>75.2 then raise exception 'Config not used'; end if;
  begin
    perform public.fauxlore_api('admin/economy/config','PATCH',jsonb_build_object('config',jsonb_set(new_cfg,'{stateEffects,crimeTaxPenalty}','1.01')),gen_random_uuid());
    raise exception 'Invalid fraction accepted';
  exception when sqlstate '22023' then null; end;
  begin
    perform public.fauxlore_api('admin/economy/config','PATCH',jsonb_build_object('config',jsonb_set(new_cfg,'{stateEffects,corruptionLoyaltyDivisor}','0')),gen_random_uuid());
    raise exception 'Zero divisor accepted';
  exception when sqlstate '22023' then null; end;
end $$;
select 'Corruption boundaries/precision, tax deductions, loyalty cap and config validation/audit/retry passed' result;
rollback;
