-- Extend the existing administrator endpoint without changing its legacy catalogue indices.
do $migration$
declare fn text; marker text; replacement text;
begin
  fn:=pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure);
  marker:=$old$  if action='snapshot' then$old$;
  replacement:=$new$  if action='resource_assign' then
    state_key:=nullif(payload->>'state_id','')::integer;
    value_key:=nullif(payload->>'value','')::numeric;
    duration_key:=nullif(payload->>'duration_turns','')::integer;
    if state_key is null or not exists(select 1 from fauxlore.state_profiles where state_id=state_key)
       or value_key is null or value_key<>trunc(value_key) or abs(value_key)>1000000000 or value_key=0
       or (duration_key is not null and (duration_key<1 or duration_key>10000))
       or coalesce(payload->>'resource','') not in ('prestige','treasury')
       or coalesce(payload->>'timing','') not in ('once','turn') then
      raise sqlstate '22023' using message='Проверьте государство, ресурс, целое значение и срок';
    end if;
    if payload->>'resource'='treasury' and coalesce(payload->>'estate','') not in ('Корона','Знать','Духовенство','Горожане','Крестьяне') then
      raise sqlstate '22023' using message='Выберите Казну';
    end if;
    if payload->>'resource'='treasury' and not exists(select 1 from fauxlore.state_treasuries where state_id=state_key and estate=payload->>'estate') then
      raise sqlstate '22023' using message='Казна выбранного сословия не найдена';
    end if;
    select * into calendar_row from fauxlore.game_calendar where singleton=true for share;
    perform 1 from fauxlore.state_profiles where state_id=state_key for update;
    if payload->>'timing'='once' then
      if duration_key is not null then raise sqlstate '22023' using message='Разовое изменение не имеет срока'; end if;
      if payload->>'resource'='prestige' then
        update fauxlore.state_profiles set prestige=prestige+value_key where state_id=state_key and prestige+value_key>=0;
      else
        update fauxlore.state_treasuries set balance=balance+value_key,updated_at=now()
          where state_id=state_key and estate=payload->>'estate' and balance+value_key>=0;
        if found then
          update fauxlore.state_profiles set treasury=(select coalesce(sum(balance),0) from fauxlore.state_treasuries where state_id=state_key) where state_id=state_key;
        end if;
      end if;
      if not found then raise sqlstate '22023' using message='Недостаточно ресурса или Казна не найдена'; end if;
    else
      if duration_key is not null then expiry_ordinal:=calendar_row.year::bigint*10000+calendar_row.turn+duration_key; end if;
      insert into fauxlore.admin_modifier_assignments(state_id,province_id,modifier_key,effect,value,unit,source,starts_year,starts_turn,expires_year,expires_turn,created_by)
      values(state_key,null,case when payload->>'resource'='prestige' then 'admin_prestige_turn' else 'admin_treasury_turn:'||(payload->>'estate') end,
        case when payload->>'resource'='prestige' then 'Престиж за ход' else 'Казна за ход · '||(payload->>'estate') end,
        value_key,case when payload->>'resource'='prestige' then 'ОП/ход' else 'G/ход' end,
        coalesce(nullif(left(btrim(payload->>'source'),120),''),'Назначение администратора'),calendar_row.year,calendar_row.turn,
        case when expiry_ordinal is null then null else floor(expiry_ordinal/10000)::integer end,
        case when expiry_ordinal is null then null else mod(expiry_ordinal,10000)::integer end,actor.id)
      returning id into modifier_key;
    end if;
    update fauxlore._settings set value_json=to_jsonb((value_json#>>'{}')::bigint+1) where key='data_revision';
    return jsonb_build_object('id',modifier_key,'status',case when payload->>'timing'='once' then 'Применён' else 'Активен' end);
  elsif action='snapshot' then$new$;
  if position(marker in fn)=0 then raise exception 'Admin API insertion point missing'; end if;
  fn:=replace(fn,marker,replacement);
  marker:='values(state_key,province_key,def.modifier_key,def.effect,value_key,def.unit,';
  replacement:='values(state_key,province_key,def.modifier_key,case when def.modifier_key=''population_growth'' then ''Прирост населения'' else def.effect end,value_key,def.unit,';
  if position(marker in fn)=0 then raise exception 'Admin API assignment point missing'; end if;
  execute replace(fn,marker,replacement);
end $migration$;

update fauxlore.admin_modifier_assignments set effect='Прирост населения'
where modifier_key='population_growth' and effect like 'Базовый прирост населения%';

-- Apply recurring resource assignments for the turn that is closing. Using OLD
-- also makes a one-turn modifier apply once before its expiry.
create or replace function fauxlore.apply_admin_resource_modifiers_on_turn()
returns trigger language plpgsql security definer set search_path='' as $function$
declare item record;
begin
  if (new.year,new.turn) <= (old.year,old.turn) then return new; end if;
  for item in select a.state_id,a.modifier_key,sum(a.value) amount
    from fauxlore.admin_modifier_assignments a
    where (a.modifier_key='admin_prestige_turn' or a.modifier_key like 'admin_treasury_turn:%')
      and (a.starts_year*10000+a.starts_turn)<=old.year*10000+old.turn
      and (a.expires_year is null or old.year*10000+old.turn<a.expires_year*10000+a.expires_turn)
    group by a.state_id,a.modifier_key order by a.state_id,a.modifier_key loop
    if item.modifier_key='admin_prestige_turn' then
      update fauxlore.state_profiles set prestige=greatest(0,prestige+item.amount) where state_id=item.state_id;
    else
      update fauxlore.state_treasuries set balance=greatest(0,balance+item.amount),updated_at=now()
        where state_id=item.state_id and estate=substring(item.modifier_key from length('admin_treasury_turn:')+1);
      update fauxlore.state_profiles set treasury=(select coalesce(sum(balance),0) from fauxlore.state_treasuries where state_id=item.state_id) where state_id=item.state_id;
    end if;
  end loop;
  return new;
end $function$;
revoke all on function fauxlore.apply_admin_resource_modifiers_on_turn() from public,anon,authenticated;
drop trigger if exists apply_admin_resource_modifiers_on_turn on fauxlore.game_calendar;
create trigger apply_admin_resource_modifiers_on_turn before update of year,turn on fauxlore.game_calendar
for each row execute function fauxlore.apply_admin_resource_modifiers_on_turn();
notify pgrst,'reload schema';
