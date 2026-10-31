alter table fauxlore.military_orders add column issued_turn integer;
update fauxlore.military_orders set issued_turn=(select turn from fauxlore.game_calendar limit 1) where issued_turn is null;
alter table fauxlore.military_orders alter column issued_turn set not null;
create or replace function fauxlore.military_order_set_turn() returns trigger language plpgsql set search_path='' as $$
begin new.issued_turn:=(select turn from fauxlore.game_calendar limit 1); return new; end $$;
create trigger military_order_set_turn before insert on fauxlore.military_orders for each row execute function fauxlore.military_order_set_turn();
do $migration$
declare definition text; revised text;
begin
  definition:=pg_get_functiondef('fauxlore.military_order_api(text,bigint,jsonb)'::regprocedure);
  revised:=replace(definition, 'if action=''approve'' then', 'if action=''approve'' and order_row.issued_turn<>(select turn from fauxlore.game_calendar limit 1) then raise sqlstate ''22023'' using message=''Ход изменился: отклоните приказ и создайте новый''; end if; if action=''approve'' then');
  revised:=replace(revised, 'if cost>limit_value then', 'limit_value:=greatest(0,limit_value-coalesce((select sum(travel_cost) from fauxlore.military_orders where formation_id=formation_key and status=''approved'' and issued_turn=(select turn from fauxlore.game_calendar limit 1)),0)); if cost>limit_value then');
  if revised=definition then raise exception 'Military order validation not found'; end if;
  execute revised;
end $migration$;
notify pgrst,'reload schema';
