alter table fauxlore.trade_settlements
  add column if not exists transit_fees jsonb not null default '[]'::jsonb
  check (jsonb_typeof(transit_fees)='array');

create or replace function fauxlore.collect_third_state_trade_toll()
returns trigger language plpgsql security definer set search_path='' as $$
declare agreement fauxlore.trade_agreements; transit_state record; current_received numeric(14,2); settled_received numeric(14,2);
  resource_value numeric(14,4); toll_quantity numeric(14,2); toll_amount numeric(14,2);
  fee_rows jsonb:='[]'::jsonb; report_value jsonb; state_treasury numeric(14,2);
begin
  select * into agreement from fauxlore.trade_agreements where id=new.agreement_id;
  if not found then return new; end if;
  current_received:=new.received;
  settled_received:=new.received;
  if new.item_kind='resource' then
    select coalesce((r->>'value')::numeric,0) into resource_value
      from fauxlore.economy_parameters ep cross join lateral jsonb_array_elements(ep.config->'resources') r
      where ep.singleton=true and r->>'name'=new.item_name;
  end if;

  for transit_state in
    select route_state.state_id,min(route_state.route_order) first_order
    from (
      select coalesce(occupier.id,owner.category_id) state_id,route.route_order
      from unnest(agreement.route_province_ids[2:array_length(agreement.route_province_ids,1)-1])
        with ordinality route(province_id,route_order)
      join fauxlore.provinces p on p.id=route.province_id
      left join fauxlore.province_values owner on owner.province_id=p.id and owner.layer='states'
      left join fauxlore.map_categories occupier on occupier.layer='states' and lower(occupier.name)=lower(p.occupation)
    ) route_state
    join fauxlore.state_profiles sp on sp.state_id=route_state.state_id
    where route_state.state_id not in (
      case when new.direction='forward' then agreement.from_state_id else agreement.to_state_id end,
      case when new.direction='forward' then agreement.to_state_id else agreement.from_state_id end
    )
    group by route_state.state_id order by min(route_state.route_order)
  loop
    if new.item_kind='resource' then
      toll_quantity:=round(current_received*0.05,2);
      current_received:=greatest(0,current_received-toll_quantity);
      toll_amount:=round(toll_quantity*coalesce(resource_value,0),2);
    else
      toll_quantity:=0;
      toll_amount:=round(current_received*0.05,2);
      current_received:=greatest(0,current_received-toll_amount);
    end if;
    if toll_amount>0 then
      insert into fauxlore.state_treasuries(state_id,estate,balance)
        values(transit_state.state_id,'Корона',toll_amount)
        on conflict(state_id,estate) do update
          set balance=fauxlore.state_treasuries.balance+excluded.balance,updated_at=now();
      update fauxlore.state_profiles sp set treasury=(select coalesce(sum(st.balance),0)
        from fauxlore.state_treasuries st where st.state_id=transit_state.state_id)
        where sp.state_id=transit_state.state_id;
    end if;
    fee_rows:=fee_rows||jsonb_build_array(jsonb_build_object(
      'state_id',transit_state.state_id,
      'state_name',(select name from fauxlore.map_categories where layer='states' and id=transit_state.state_id),
      'item_kind',new.item_kind,'item_name',new.item_name,
      'resource_quantity',toll_quantity,'amount',toll_amount));

    select report into report_value from fauxlore.turn_economy_reports where year=new.year and turn=new.turn for update;
    if report_value is not null then
      select coalesce(jsonb_agg(case when (value->>'id')::integer=transit_state.state_id
        then value||jsonb_build_object(
          'trade_transit_income',coalesce((value->>'trade_transit_income')::numeric,0)+toll_amount,
          'closing_treasury',(select coalesce(sum(balance),0) from fauxlore.state_treasuries where state_id=transit_state.state_id),
          'tax_buckets',coalesce(value->'tax_buckets','{}'::jsonb)||jsonb_build_object('Корона',
            coalesce((select balance from fauxlore.state_treasuries where state_id=transit_state.state_id and estate='Корона'),0)))
        else value end order by ord),'[]'::jsonb)
        into report_value from jsonb_array_elements(report_value) with ordinality rows(value,ord);
      if not exists(select 1 from jsonb_array_elements(report_value) entry(value)
          where (value->>'id')::integer=transit_state.state_id) then
        select coalesce(sum(balance),0) into state_treasury from fauxlore.state_treasuries where state_id=transit_state.state_id;
        report_value:=report_value||jsonb_build_array(jsonb_build_object(
          'id',transit_state.state_id,
          'name',(select name from fauxlore.map_categories where layer='states' and id=transit_state.state_id),
          'province_count',0,'gross_taxes',0,'crown_taxes',0,'estate_taxes',0,
          'tax_details','[]'::jsonb,'tax_buckets',jsonb_build_object('Корона',
            coalesce((select balance from fauxlore.state_treasuries where state_id=transit_state.state_id and estate='Корона'),0)),
          'trade_transit_income',toll_amount,'closing_treasury',state_treasury));
      end if;
      update fauxlore.turn_economy_reports set report=report_value where year=new.year and turn=new.turn;
    end if;
  end loop;

  if jsonb_array_length(fee_rows)>0 then
    new.received:=current_received;
    new.lost:=new.sent-current_received;
    new.transit_fees:=fee_rows;
    if new.item_kind='resource' then
      update pg_temp.trade_turn_stock set available=greatest(0,available-(settled_received-current_received))
        where state_id=case when new.direction='forward' then agreement.to_state_id else agreement.from_state_id end
          and resource_name=new.item_name;
    else
      update fauxlore.state_treasuries set balance=greatest(0,balance-(settled_received-current_received)),updated_at=now()
        where state_id=case when new.direction='forward' then agreement.to_state_id else agreement.from_state_id end and estate='Корона';
    end if;
    -- AFTER INSERT triggers cannot change NEW; persist the adjusted settlement and
    -- the already-updated destination balance/stock in the same turn transaction.
    update fauxlore.trade_settlements set received=new.received,lost=new.lost,transit_fees=fee_rows
      where agreement_id=new.agreement_id and year=new.year and turn=new.turn
        and direction=new.direction and item_kind=new.item_kind and item_name=new.item_name;
  end if;
  return null;
end $$;
revoke all on function fauxlore.collect_third_state_trade_toll() from public,anon,authenticated;
drop trigger if exists trade_settlements_third_state_toll on fauxlore.trade_settlements;
create trigger trade_settlements_third_state_toll after insert on fauxlore.trade_settlements
for each row execute function fauxlore.collect_third_state_trade_toll();

do $$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.trade_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:=$old$where actor.role='admin' or exists(select 1 from fauxlore.account_states ast where ast.account_id=actor.id and ast.layer='states' and ast.state_id in(ta.from_state_id,ta.to_state_id))$old$;
  new_fragment:=$new$where actor.role='admin' or exists(select 1 from fauxlore.account_states ast where ast.account_id=actor.id and ast.layer='states' and ast.state_id in(ta.from_state_id,ta.to_state_id))
        or exists(select 1 from jsonb_array_elements(ts.transit_fees) fee join fauxlore.account_states ast
          on ast.account_id=actor.id and ast.layer='states' and ast.state_id=(fee->>'state_id')::integer)$new$;
  if position('jsonb_array_elements(ts.transit_fees)' in fn)=0 then
    if position(old_fragment in fn)=0 then raise exception 'Could not locate trade settlement access filter'; end if;
    fn:=replace(fn,old_fragment,new_fragment);
  end if;
  old_fragment:=$old$'requested',ts.requested,'sent',ts.sent,'received',ts.received,'lost',ts.lost)$old$;
  new_fragment:=$new$'requested',ts.requested,'sent',ts.sent,'received',ts.received,'lost',ts.lost,'transit_fees',ts.transit_fees)$new$;
  if position('''transit_fees'',ts.transit_fees' in fn)=0 then
    if position(old_fragment in fn)=0 then raise exception 'Could not locate settlement API response fields'; end if;
    fn:=replace(fn,old_fragment,new_fragment);
  end if;
  execute fn;
end $$;
notify pgrst,'reload schema';
