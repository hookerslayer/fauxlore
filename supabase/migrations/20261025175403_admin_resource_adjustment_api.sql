create or replace function fauxlore.admin_resources_api(action text, target_state integer default null, resource text default null, delta integer default 0)
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  actor fauxlore.accounts;
  state_row fauxlore.state_profiles;
  current_value numeric;
  updated_treasury numeric;
begin
  actor:=fauxlore.current_account();
  if coalesce(actor.role,'')<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if action='snapshot' then
    return coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',c.id,'name',c.name,
        'treasury',coalesce((select st.balance from fauxlore.state_treasuries st where st.state_id=c.id and st.estate='Корона'),0),
        'prestige',coalesce(sp.prestige,0),'recruits',coalesce(sp.recruits,0)
      ) order by c.name)
      from fauxlore.map_categories c left join fauxlore.state_profiles sp on sp.state_id=c.id
      where c.layer='states'
    ),'[]'::jsonb);
  end if;
  if action<>'adjust' or target_state is null or resource not in ('treasury','prestige','recruits')
     or delta=0 or abs(delta)>1000000000 then
    raise sqlstate '22023' using message='Некорректные параметры изменения ресурсов';
  end if;
  select * into state_row from fauxlore.state_profiles where state_id=target_state for update;
  if not found then raise sqlstate 'P0002' using message='Государство не найдено'; end if;
  if resource='treasury' then
    select balance into current_value from fauxlore.state_treasuries where state_id=target_state and estate='Корона' for update;
    if not found then raise sqlstate 'P0002' using message='Казна государства не найдена'; end if;
  elsif resource='prestige' then current_value:=state_row.prestige;
  else current_value:=state_row.recruits;
  end if;
  if current_value+delta<0 then raise sqlstate '22023' using message='Значение ресурса не может быть меньше нуля'; end if;
  if resource='treasury' then
    update fauxlore.state_treasuries set balance=balance+delta,updated_at=now() where state_id=target_state and estate='Корона';
    select coalesce(sum(balance),0) into updated_treasury from fauxlore.state_treasuries where state_id=target_state;
    update fauxlore.state_profiles set treasury=updated_treasury where state_id=target_state;
  elsif resource='prestige' then update fauxlore.state_profiles set prestige=prestige+delta where state_id=target_state;
  else update fauxlore.state_profiles set recruits=recruits+delta where state_id=target_state;
  end if;
  update fauxlore._settings set value_json=to_jsonb((value_json#>>'{}')::bigint+1) where key='data_revision';
  return (select jsonb_build_object(
    'id',c.id,'name',c.name,
    'treasury',coalesce((select st.balance from fauxlore.state_treasuries st where st.state_id=c.id and st.estate='Корона'),0),
    'prestige',coalesce(sp.prestige,0),'recruits',coalesce(sp.recruits,0)
  ) from fauxlore.map_categories c left join fauxlore.state_profiles sp on sp.state_id=c.id
    where c.layer='states' and c.id=target_state);
end
$function$;
revoke all on function fauxlore.admin_resources_api(text,integer,text,integer) from public,anon,authenticated;
grant execute on function fauxlore.admin_resources_api(text,integer,text,integer) to authenticated;

create or replace function public.admin_resources_api(action text, target_state integer default null, resource text default null, delta integer default 0)
returns jsonb language sql security invoker set search_path=pg_catalog,fauxlore
as $function$
  select fauxlore.admin_resources_api(action,target_state,resource,delta);
$function$;
revoke all on function public.admin_resources_api(text,integer,text,integer) from public,anon;
grant execute on function public.admin_resources_api(text,integer,text,integer) to authenticated;
notify pgrst, 'reload schema';
