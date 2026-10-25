-- Replace the temporary army budget with formation accounting.
create or replace function fauxlore.charge_army_upkeep_before_turn()
returns trigger language plpgsql security definer set search_path='' as $$
declare report_value jsonb; state_row record; formation_row record; cost numeric; total_cost numeric;
 crown_balance numeric; closing_balance numeric; details jsonb; unpaid_mercenaries integer; home_city integer;
begin
 if new.year=old.year and new.turn=old.turn then return new; end if;
 select report into report_value from fauxlore.turn_economy_reports where year=old.year and turn=old.turn for update;
 if report_value is null then raise sqlstate '22023' using message='Не найден налоговый отчёт для расчётного хода'; end if;
 for state_row in select state_id from fauxlore.state_profiles order by state_id loop
  select balance into crown_balance from fauxlore.state_treasuries where state_id=state_row.state_id and estate='Корона' for update;
  crown_balance:=coalesce(crown_balance,0);total_cost:=0;details:='[]'::jsonb;unpaid_mercenaries:=0;
  for formation_row in select f.*,g.price mercenary_price,g.city_province_id,
     (select coalesce(sum(case when u.name='Копейщик' then greatest(0,fu.quantity-f.free_upkeep_quantity)*u.upkeep
       else fu.quantity*u.upkeep end),0) from fauxlore.military_formation_units fu
       join fauxlore.military_unit_catalog u on u.id=fu.unit_id where fu.formation_id=f.id) regular_cost
     from fauxlore.military_formations f left join fauxlore.mercenary_groups g on g.id=f.mercenary_group_id
     where f.state_id=state_row.state_id and f.active order by f.id loop
    cost:=case when formation_row.kind='mercenary' then formation_row.mercenary_price else formation_row.regular_cost end;
    if formation_row.kind='mercenary' and crown_balance-total_cost<cost then
      update fauxlore.military_formations set active=false,province_id=formation_row.city_province_id where id=formation_row.id;
      update fauxlore.provinces set development=greatest(0,coalesce(development,0)-5) where id=formation_row.city_province_id;
      unpaid_mercenaries:=unpaid_mercenaries+1;
      details:=details||jsonb_build_array(jsonb_build_object('formation_id',formation_row.id,'name',formation_row.name,'dissolved',true));
    else
      total_cost:=total_cost+cost;
      details:=details||jsonb_build_array(jsonb_build_object('formation_id',formation_row.id,'name',formation_row.name,'cost',cost));
    end if;
  end loop;
  if unpaid_mercenaries>0 then
    update fauxlore.state_group_politics set loyalty=greatest(0,loyalty-.05*unpaid_mercenaries),
      recovery_target=least(1,coalesce(recovery_target,loyalty)+.005*unpaid_mercenaries)
      where state_id=state_row.state_id and group_type='estate' and group_key='Горожане';
  end if;
  if total_cost<>0 then
    update fauxlore.state_treasuries set balance=balance-total_cost,updated_at=now()
      where state_id=state_row.state_id and estate='Корона';
    insert into fauxlore.state_budget_ledger(state_id,estate,year,turn,kind,unit_type_id,cash_delta,debt_delta,details)
      values(state_row.state_id,'Корона',old.year,old.turn,'army_upkeep',null,-total_cost,0,
        jsonb_build_object('formations',details));
  end if;
  select coalesce(sum(balance),0) into closing_balance from fauxlore.state_treasuries where state_id=state_row.state_id;
  update fauxlore.state_profiles set treasury=closing_balance where state_id=state_row.state_id;
  select coalesce(jsonb_agg(case when (x.value->>'id')::integer=state_row.state_id then
   x.value||jsonb_build_object('army_upkeep',total_cost,'army_upkeep_paid',total_cost,
     'army_upkeep_arrears',0,'closing_treasury',closing_balance,'army_details',details,
     'tax_buckets',coalesce(x.value->'tax_buckets','{}'::jsonb)||jsonb_build_object('Корона',crown_balance-total_cost))
   else x.value end order by x.ord),'[]'::jsonb) into report_value
   from jsonb_array_elements(report_value) with ordinality x(value,ord);
 end loop;
 update fauxlore.turn_economy_reports set report=report_value where year=old.year and turn=old.turn;
 return new;
end $$;
revoke all on function fauxlore.charge_army_upkeep_before_turn() from public,anon,authenticated;

create or replace function fauxlore.military_finish_turn()
returns trigger language plpgsql security definer set search_path='' as $$
declare state_row record; recruit_cap integer; current_reserve integer;
begin
 for state_row in select state_id from fauxlore.state_profiles order by state_id loop
   recruit_cap:=greatest(0,coalesce((fauxlore.state_recruitment(state_row.state_id)->>'recruit_limit')::integer,0));
   update fauxlore.state_profiles set recruits=least(recruits,recruit_cap) where state_id=state_row.state_id returning recruits into current_reserve;
   update fauxlore.turn_economy_reports set report=(select jsonb_agg(case when (v.value->>'id')::integer=state_row.state_id
     then v.value||jsonb_build_object('recruits_after',current_reserve) else v.value end order by v.ord)
     from jsonb_array_elements(report) with ordinality v(value,ord)) where year=new.year and turn=new.turn;
   if not exists(select 1 from fauxlore.military_wars where active and (attacker_id=state_row.state_id or defender_id=state_row.state_id)) then
     update fauxlore.military_traditions set land=greatest(0,land-2),naval=greatest(0,naval-2) where state_id=state_row.state_id;
   end if;
 end loop;
 return new;
end $$;
revoke all on function fauxlore.military_finish_turn() from public,anon,authenticated;
create trigger zzzzzz_military_finish_turn after insert on fauxlore.turn_economy_reports
 for each row execute function fauxlore.military_finish_turn();

create or replace function fauxlore.military_capital_created() returns trigger language plpgsql security definer set search_path='' as $$
declare formation_key bigint; spearman_key bigint;
begin
 if new.type='capital' and new.state_id is not null and exists(select 1 from fauxlore.state_profiles where state_id=new.state_id)
    and not exists(select 1 from fauxlore.military_formations where state_id=new.state_id and name='Стартовое войско') then
   insert into fauxlore.military_formations(state_id,name,domain,province_id,free_upkeep_quantity)
     values(new.state_id,'Стартовое войско','land',new.province_id,300) returning id into formation_key;
   select id into spearman_key from fauxlore.military_unit_catalog where name='Копейщик';
   insert into fauxlore.military_formation_units values(formation_key,spearman_key,300);
 end if;
 return new;
end $$;
revoke all on function fauxlore.military_capital_created() from public,anon,authenticated;
create trigger military_capital_created after insert on fauxlore.map_markers for each row execute function fauxlore.military_capital_created();
