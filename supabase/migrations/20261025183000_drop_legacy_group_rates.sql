-- Keep the treasury read endpoint while retiring the unused race/religion rate table.
CREATE OR REPLACE FUNCTION fauxlore.state_tax_rates_api(path text, method text, body jsonb, request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a fauxlore.accounts; state_key integer; state_name text; calendar_row fauxlore.game_calendar; is_admin boolean;
begin
  a:=fauxlore.current_account(); is_admin:=a.role='admin';
  if path='admin/economy/treasuries' and method='GET' then
    if not is_admin then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('id',s.state_id,'name',c.name,'treasury',s.treasury,'prestige',s.prestige,
      'debt',coalesce(d.balance,0),'players',coalesce((select jsonb_agg(ac.nickname order by ac.nickname) from fauxlore.account_states ast join fauxlore.accounts ac on ac.id=ast.account_id where ast.layer='states' and ast.state_id=s.state_id and ac.role<>'admin'),'[]'::jsonb),
      'buckets',coalesce((select jsonb_object_agg(t.estate,t.balance order by t.estate) from fauxlore.state_treasuries t where t.state_id=s.state_id),'{}'::jsonb)) order by c.name)
      from fauxlore.state_profiles s join fauxlore.map_categories c on c.layer='states' and c.id=s.state_id
      left join fauxlore.state_treasury_debts d on d.state_id=s.state_id),'[]'::jsonb);
  end if;
  if path !~ '^(my|admin)/states/[0-9]+/tax-rates$' then raise sqlstate 'P0002' using message='Метод API не найден'; end if;
  if (path like 'admin/%') is distinct from is_admin then raise sqlstate '42501' using message='Недостаточно прав'; end if;
  state_key:=substring(path from '[0-9]+')::integer;
  if not exists(select 1 from fauxlore.state_profiles where state_id=state_key) then raise sqlstate 'P0002' using message='Государство не найдено'; end if;
  if not is_admin and not exists(select 1 from fauxlore.account_states ast where ast.account_id=a.id and ast.layer='states' and ast.state_id=state_key) then
    raise sqlstate '42501' using message='Это государство не закреплено за вашим аккаунтом'; end if;
  select * into calendar_row from fauxlore.game_calendar where singleton=true;
  select c.name into state_name from fauxlore.map_categories c where c.layer='states' and c.id=state_key;
  if method='GET' then
    return jsonb_build_object('state_id',state_key,'state_name',state_name,'year',calendar_row.year,'turn',calendar_row.turn,
      'prestige',(select prestige from fauxlore.state_profiles where state_id=state_key),
      'treasury',(select treasury from fauxlore.state_profiles where state_id=state_key),
      'debt',coalesce((select balance from fauxlore.state_treasury_debts where state_id=state_key),0),
      'buckets',coalesce((select jsonb_object_agg(estate,balance) from fauxlore.state_treasuries where state_id=state_key),'{}'::jsonb),
      'army_upkeep_forecast',(select coalesce(sum(u.quantity*t.upkeep_per_unit),0)
        from fauxlore.state_army_units u join fauxlore.army_unit_types t on t.id=u.unit_type_id where u.state_id=state_key),
      'groups','[]'::jsonb);
  end if;
  raise sqlstate 'P0002' using message='Налоговые ставки рас и религий отменены';
end $function$
;
drop table fauxlore.state_tax_rates;
