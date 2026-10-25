-- The internal-market duty is the Crown's share of the fulfilled domestic
-- turnover. Distribute the remainder to estates using the same relative
-- estate weights as trade-zone income (10:5:65:5, excluding the Crown).
do $migration$
declare
  fn text;
  changed text;
  old_loop text;
  new_loop text;
begin
  fn:=pg_get_functiondef('fauxlore.finish_trade_value_turn()'::regprocedure);

  changed:=replace(fn,
    'for rec in select state_id,sum(duty_income) duty from fauxlore.trade_state_resource_turns',
    'for rec in select state_id,sum(duty_income) duty,sum(turnover) turnover from fauxlore.trade_state_resource_turns');
  if changed=fn then
    raise exception 'Could not extend internal trade totals in finish_trade_value_turn';
  end if;

  old_loop:=$old$
    if rec.duty+total_market<>0 then
      insert into fauxlore.state_treasuries(state_id,estate,balance) values(rec.state_id,'Корона',rec.duty+total_market)
        on conflict(state_id,estate) do update set balance=fauxlore.state_treasuries.balance+excluded.balance,updated_at=now();
    end if;
$old$;
  new_loop:=$new$
    -- Zone income is temporarily credited to the Crown and reallocated by
    -- distribute_trade_zone_income_to_estates() after the turn report insert.
    -- Internal turnover is split here: the duty is the Crown's actual share.
    if rec.duty+total_market<>0 then
      insert into fauxlore.state_treasuries(state_id,estate,balance) values(rec.state_id,'Корона',rec.duty+total_market)
        on conflict(state_id,estate) do update set balance=fauxlore.state_treasuries.balance+excluded.balance,updated_at=now();
    end if;
    total_duty:=greatest(0,floor(rec.turnover-rec.duty));
    if total_duty>0 then
      insert into fauxlore.state_treasuries(state_id,estate,balance)
      values
        (rec.state_id,'Знать',floor(total_duty*10/85)),
        (rec.state_id,'Духовенство',floor(total_duty*5/85)),
        (rec.state_id,'Горожане',floor(total_duty*65/85)),
        (rec.state_id,'Крестьяне',total_duty-floor(total_duty*10/85)-floor(total_duty*5/85)-floor(total_duty*65/85))
      on conflict(state_id,estate) do update
        set balance=fauxlore.state_treasuries.balance+excluded.balance,updated_at=now();
    end if;
$new$;

  if position(old_loop in changed)=0 then
    raise exception 'Could not locate Crown credit block in finish_trade_value_turn';
  end if;
  changed:=replace(changed,old_loop,new_loop);
  execute changed;
end
$migration$;
