-- Договор, принятый в текущем ходу, должен рассчитываться в конце этого же
-- хода. Раньше условие требовало accepted_turn < turn расчёта, поэтому
-- договор, заключённый в первой половине хода, пропускал целый ход.
do $migration$
declare definition text; old_part text; new_part text;
begin
  definition:=pg_get_functiondef('fauxlore.settle_trade_contracts_after_budget()'::regprocedure);
  if position('ta.accepted_year*10000+ta.accepted_turn' in definition)=0 then
    old_part:=$m$    where ta.status='accepted' and (ta.accepted_year,new.turn) is not null
      and (ta.accepted_year<new.year or (ta.accepted_year=new.year and ta.accepted_turn<new.turn))$m$;
    if position(old_part in definition)=0 then raise exception 'Trade settlement turn filter changed'; end if;
    new_part:=$m$    where ta.status='accepted' and ta.accepted_year is not null and ta.accepted_turn is not null
      and (ta.accepted_year*10000+ta.accepted_turn)<=(new.year*10000+new.turn)$m$;
    execute replace(definition,old_part,new_part);
  end if;
end $migration$;

notify pgrst,'reload schema';
