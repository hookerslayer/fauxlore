-- Distribute each state's earned trade-zone income across its five treasuries.
-- finish_trade_value_turn() has already credited the full amount to the Crown
-- in its earlier AFTER INSERT trigger; this later trigger reallocates it.
create or replace function fauxlore.distribute_trade_zone_income_to_estates()
returns trigger
language plpgsql
set search_path=''
as $$
declare
  income_row record;
  estate_row record;
  crown_amount numeric(18,2);
  nobility_amount numeric(18,2);
  clergy_amount numeric(18,2);
  burghers_amount numeric(18,2);
  peasants_amount numeric(18,2);
begin
  for income_row in
    select state_id,round(sum(local_income+export_income),2) as amount
    from fauxlore.trade_zone_income_turns
    where year=new.year and turn=new.turn
    group by state_id
  loop
    if income_row.amount<=0 then continue; end if;

    crown_amount:=round(income_row.amount*0.15,2);
    nobility_amount:=round(income_row.amount*0.10,2);
    clergy_amount:=round(income_row.amount*0.05,2);
    burghers_amount:=round(income_row.amount*0.65,2);
    peasants_amount:=income_row.amount-crown_amount-nobility_amount-clergy_amount-burghers_amount;

    update fauxlore.state_treasuries
    set balance=balance-income_row.amount,updated_at=now()
    where state_id=income_row.state_id and estate='Корона';

    for estate_row in
      select shares.estate,shares.amount
      from (values
        ('Корона'::text,crown_amount),('Знать'::text,nobility_amount),
        ('Духовенство'::text,clergy_amount),('Горожане'::text,burghers_amount),
        ('Крестьяне'::text,peasants_amount)
      ) as shares(estate,amount)
    loop
      if estate_row.amount=0 then continue; end if;
      insert into fauxlore.state_treasuries(state_id,estate,balance)
      values(income_row.state_id,estate_row.estate,estate_row.amount)
      on conflict(state_id,estate) do update
        set balance=fauxlore.state_treasuries.balance+excluded.balance,updated_at=now();
    end loop;
  end loop;

  update fauxlore.state_profiles state_profile
  set treasury=(select coalesce(sum(treasury.balance),0)
    from fauxlore.state_treasuries treasury where treasury.state_id=state_profile.state_id)
  where exists(select 1 from fauxlore.trade_zone_income_turns income
    where income.year=new.year and income.turn=new.turn and income.state_id=state_profile.state_id);

  return null;
end;
$$;

revoke all on function fauxlore.distribute_trade_zone_income_to_estates() from public,anon,authenticated;
drop trigger if exists zzzzzz_trade_zone_income_estate_allocation on fauxlore.turn_economy_reports;
create trigger zzzzzz_trade_zone_income_estate_allocation
after insert on fauxlore.turn_economy_reports
for each row execute function fauxlore.distribute_trade_zone_income_to_estates();
