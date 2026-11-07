-- Администратор отменяет ещё не завершённое строительство и возвращает
-- списанные деньги, либо сносит уже построенный порт и компенсирует его
-- стоимость. Сумма берётся из сохранённой стоимости проекта или постройки,
-- поэтому возврат всегда равен исходному списанию.
--
-- Возврат пишется в журнал бюджета видом `admin_refund`, чтобы компенсация
-- была видна в отчётности и не выглядела «потерянными» деньгами.

alter table fauxlore.state_budget_ledger drop constraint if exists state_budget_ledger_kind_check;
alter table fauxlore.state_budget_ledger add constraint state_budget_ledger_kind_check
  check (kind in ('army_upkeep','debt_repayment','estate_loyalty_investment','estate_military_tax','port_upkeep','admin_refund'));

create or replace function fauxlore.refund_state_cash(state_key integer, amount numeric, reason text)
returns numeric language plpgsql security definer set search_path='' as $function$
declare year_value integer; turn_value integer; updated numeric;
begin
  if state_key is null or amount is null or amount<=0 then return 0; end if;
  update fauxlore.state_treasuries set balance=balance+amount,updated_at=now()
    where state_id=state_key and estate='Корона';
  if not found then
    insert into fauxlore.state_treasuries(state_id,estate,balance) values(state_key,'Корона',amount);
  end if;
  select coalesce(sum(balance),0) into updated from fauxlore.state_treasuries where state_id=state_key;
  update fauxlore.state_profiles set treasury=updated where state_id=state_key;
  select year,turn into year_value,turn_value from fauxlore.game_calendar where singleton;
  insert into fauxlore.state_budget_ledger(state_id,estate,year,turn,kind,cash_delta,debt_delta,details)
    values(state_key,'Корона',year_value,turn_value,'admin_refund',amount,0,jsonb_build_object('reason',reason));
  return amount;
end
$function$;
revoke all on function fauxlore.refund_state_cash(integer,numeric,text) from public,anon,authenticated;

create or replace function fauxlore.admin_rollback_api(action text, payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; project_row fauxlore.military_port_projects; garrison_row fauxlore.garrison_projects;
  marker_row fauxlore.map_markers; build_row fauxlore.military_port_builds; refund numeric; state_key integer;
  province_name text; project_key bigint; marker_key bigint;
begin
  actor:=fauxlore.current_account();
  if actor.id is null then raise sqlstate '42501' using message='Требуется вход'; end if;
  if actor.role<>'admin' then raise sqlstate '42501' using message='Доступно только администратору'; end if;

  if action='snapshot' then
    return jsonb_build_object(
      'port_projects',coalesce((select jsonb_agg(jsonb_build_object(
          'id',pp.id,'state_id',pp.state_id,
          'state_name',(select c.name from fauxlore.map_categories c where c.layer='states' and c.id=pp.state_id),
          'province_name',(select p.name from fauxlore.provinces p where p.id=pp.sea_province_id),
          'cost',pp.cost,'turns_remaining',pp.turns_remaining) order by pp.id)
        from fauxlore.military_port_projects pp where pp.status='building'),'[]'::jsonb),
      'ports',coalesce((select jsonb_agg(jsonb_build_object(
          'marker_id',m.id,'name',m.name,
          'province_name',(select p.name from fauxlore.provinces p where p.id=m.province_id),
          'state_id',coalesce(m.state_id,b.state_id),
          'state_name',(select c.name from fauxlore.map_categories c where c.layer='states' and c.id=coalesce(m.state_id,b.state_id)),
          'cost',b.cost) order by m.id)
        from fauxlore.map_markers m
        left join fauxlore.military_port_builds b on b.marker_id=m.id
        where m.type='port'),'[]'::jsonb),
      'garrison_projects',coalesce((select jsonb_agg(jsonb_build_object(
          'id',gp.id,'state_id',gp.state_id,
          'state_name',(select c.name from fauxlore.map_categories c where c.layer='states' and c.id=gp.state_id),
          'province_name',(select p.name from fauxlore.provinces p where p.id=gp.province_id),
          'kind',gp.kind,'target_level',gp.target_level,'cost',gp.cost) order by gp.id)
        from fauxlore.garrison_projects gp where gp.status='building'),'[]'::jsonb)
    );
  end if;

  if action='cancel_port_project' then
    project_key:=(payload->>'project_id')::bigint;
    select * into project_row from fauxlore.military_port_projects
      where id=project_key and status='building' for update;
    if not found then raise sqlstate 'P0002' using message='Строительство порта не найдено или уже завершено'; end if;
    select name into province_name from fauxlore.provinces where id=project_row.sea_province_id;
    delete from fauxlore.military_port_projects where id=project_key;
    refund:=fauxlore.refund_state_cash(project_row.state_id,project_row.cost,
      format('Отмена строительства порта в провинции «%s»',province_name));
    insert into fauxlore.notifications(account_id,kind,title,message)
      select a.account_id,'construction','Строительство отменено',
        format('Администратор отменил строительство порта в провинции «%s». Возвращено %s G.',province_name,refund)
      from fauxlore.account_states a where a.state_id=project_row.state_id;
    return jsonb_build_object('cancelled',true,'refunded',refund);
  end if;

  if action='cancel_port' then
    marker_key:=(payload->>'marker_id')::bigint;
    select * into marker_row from fauxlore.map_markers where id=marker_key and type='port' for update;
    if not found then raise sqlstate 'P0002' using message='Порт не найден'; end if;
    select * into build_row from fauxlore.military_port_builds where marker_id=marker_key;
    state_key:=coalesce(marker_row.state_id,build_row.state_id);
    delete from fauxlore.map_markers where id=marker_key;
    refund:=case when build_row.cost is null then 0
      else fauxlore.refund_state_cash(state_key,build_row.cost,
        format('Снос порта «%s» администратором',marker_row.name)) end;
    if state_key is not null then
      insert into fauxlore.notifications(account_id,kind,title,message)
        select a.account_id,'construction','Порт снесён администратором',
          format('Порт «%s» снесён. Возвращено %s G.',marker_row.name,refund)
        from fauxlore.account_states a where a.state_id=state_key;
    end if;
    return jsonb_build_object('cancelled',true,'refunded',refund);
  end if;

  if action='cancel_garrison_project' then
    project_key:=(payload->>'project_id')::bigint;
    select * into garrison_row from fauxlore.garrison_projects
      where id=project_key and status='building' for update;
    if not found then raise sqlstate 'P0002' using message='Строительство укрепления не найдено или уже завершено'; end if;
    select name into province_name from fauxlore.provinces where id=garrison_row.province_id;
    delete from fauxlore.garrison_projects where id=project_key;
    refund:=fauxlore.refund_state_cash(garrison_row.state_id,garrison_row.cost,
      format('Отмена строительства в провинции «%s»',province_name));
    insert into fauxlore.notifications(account_id,kind,title,message)
      select a.account_id,'construction','Строительство отменено',
        format('Администратор отменил строительство в провинции «%s». Возвращено %s G.',province_name,refund)
      from fauxlore.account_states a where a.state_id=garrison_row.state_id;
    return jsonb_build_object('cancelled',true,'refunded',refund);
  end if;

  raise sqlstate '22023' using message='Неизвестное действие отката';
end
$function$;
revoke all on function fauxlore.admin_rollback_api(text,jsonb) from public,anon,authenticated;
grant execute on function fauxlore.admin_rollback_api(text,jsonb) to authenticated;
