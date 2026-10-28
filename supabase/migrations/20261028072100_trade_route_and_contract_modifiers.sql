-- Resolve prestige action/contract costs and trade-route range bonuses.
create or replace function fauxlore.permanent_prestige_action_cost(target_state integer,base_cost integer)
returns integer language sql stable security definer set search_path=''
as $function$
select greatest(0,base_cost+floor(fauxlore.state_permanent_modifier_total(target_state,array['prestige_action_cost'],null,null)))::integer
$function$;
revoke all on function fauxlore.permanent_prestige_action_cost(integer,integer) from public,anon,authenticated;

create or replace function fauxlore.permanent_prestige_contract_cost(target_state integer,base_cost integer)
returns integer language sql stable security definer set search_path=''
as $function$
select greatest(0,base_cost+floor(fauxlore.state_permanent_modifier_total(target_state,array['prestige_contract_cost'],null,null)))::integer
$function$;
revoke all on function fauxlore.permanent_prestige_contract_cost(integer,integer) from public,anon,authenticated;

do $patch$
declare definition text; marker text; replacement text;
begin
  select pg_get_functiondef('fauxlore.trade_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  definition:=replace(definition,'route_ids integer[]; route_len integer; segment integer;',
    'route_ids integer[]; route_len integer; route_limit integer; segment integer;');
  marker:=$m$if jsonb_array_length(body->'route_province_ids') not between 2 and 10 or exists($m$;
  replacement:=$m$if jsonb_array_length(body->'route_province_ids') not between 2 and 20 or exists($m$;
  if position(marker in definition)=0 then raise exception 'Trade route length validation not found'; end if;
  definition:=replace(definition,marker,replacement);
  definition:=replace(definition,'Маршрут должен содержать от 2 до 10 ID провинций по порядку','Маршрут превышает допустимую длину или содержит неверные ID');
  marker:=$m$route_len:=array_length(route_ids,1);$m$;
  replacement:=$m$route_len:=array_length(route_ids,1);
    route_limit:=10+floor(fauxlore.state_permanent_modifier_total(state_from,
      case when exists(select 1 from unnest(route_ids) as route_item(id) join fauxlore.provinces p on p.id=route_item.id where p.kind='sea')
        then array['sea_trade_range'] else array['land_trade_range'] end,null,null))::integer;
    if route_len>route_limit then raise sqlstate '22023' using message='Превышена торговая дистанция государства ('||route_limit||' пров.)'; end if;$m$;
  if position(marker in definition)=0 then raise exception 'Trade route length calculation not found'; end if;
  definition:=replace(definition,marker,replacement);
  marker:=$m$cost_value:=case when actor.role='admin' then 0 else 3 end;$m$;
  replacement:=$m$cost_value:=case when actor.role='admin' then 0 else
      fauxlore.permanent_prestige_action_cost(state_from,3)+
      floor(fauxlore.state_permanent_modifier_total(state_from,array['prestige_contract_cost'],null,null))::smallint end;$m$;
  if position(marker in definition)=0 then raise exception 'Trade proposal prestige cost not found'; end if;
  execute replace(definition,marker,replacement);
end
$patch$;

do $patch$
declare definition text; marker text; replacement text;
begin
  select pg_get_functiondef('fauxlore.estate_tax_rates_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  marker:=$m$update fauxlore.state_profiles set prestige=prestige-3 where state_id=target_state and prestige>=3;$m$;
  replacement:=$m$update fauxlore.state_profiles set prestige=prestige-fauxlore.permanent_prestige_action_cost(target_state,3)
      where state_id=target_state and prestige>=fauxlore.permanent_prestige_action_cost(target_state,3);$m$;
  if position(marker in definition)>0 then definition:=replace(definition,marker,replacement); end if;
  definition:=replace(definition,'Недостаточно ОП: изменение ставки стоит 3 ОП','Недостаточно ОП для изменения налоговой ставки с учётом принципов государства');
  definition:=replace(definition,'''cost'',case when is_admin then 0 else 3 end','''cost'',case when is_admin then 0 else fauxlore.permanent_prestige_action_cost(target_state,3) end');
  execute definition;

  select pg_get_functiondef('fauxlore.state_trade_duty_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  marker:=$m$update fauxlore.state_profiles set prestige=prestige-3 where state_id=state_key and prestige>=3;$m$;
  replacement:=$m$update fauxlore.state_profiles set prestige=prestige-fauxlore.permanent_prestige_action_cost(state_key,3)
      where state_id=state_key and prestige>=fauxlore.permanent_prestige_action_cost(state_key,3);$m$;
  if position(marker in definition)>0 then definition:=replace(definition,marker,replacement); end if;
  definition:=replace(definition,'Недостаточно ОП: изменение пошлины стоит 3 ОП','Недостаточно ОП для изменения пошлины с учётом принципов государства');
  definition:=replace(definition,'''cost'',case when is_admin then 0 else 3 end','''cost'',case when is_admin then 0 else fauxlore.permanent_prestige_action_cost(state_key,3) end');
  execute definition;
end
$patch$;

notify pgrst,'reload schema';
