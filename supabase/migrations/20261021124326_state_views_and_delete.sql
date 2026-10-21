create or replace function fauxlore.game_state_api(path text, method text, body jsonb, request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  a fauxlore.accounts;
  state_value integer;
  state_name text;
  result jsonb;
  previous fauxlore.operations;
  fingerprint text;
  province_count integer;
  removed_assignments integer;
  unlinked_markers integer;
begin
  if jsonb_typeof(body) is distinct from 'object' then
    raise sqlstate '22023' using message='Некорректный запрос';
  end if;

  a:=fauxlore.current_account();

  if path='my/states' and method='GET' then
    select coalesce(jsonb_agg(item order by item->>'name'),'[]'::jsonb) into result
    from (
      select jsonb_build_object(
        'id',c.id,'name',c.name,'color',c.color,
        'is_npc',coalesce(sp.is_npc,true),
        'form_name',sp.government_name,'principles',sp.principles,
        'official_race',(select name from fauxlore.map_categories where layer='races' and id=sp.official_race_id),
        'official_religion',(select name from fauxlore.map_categories where layer='religions' and id=sp.official_religion_id),
        'corruption',coalesce(sp.corruption,0.2),
        'province_count',(select count(*) from fauxlore.province_values v join fauxlore.provinces p on p.id=v.province_id where v.layer='states' and v.category_id=c.id and p.kind='land'),
        'population',(select coalesce(sum(p.population),0) from fauxlore.province_values v join fauxlore.provinces p on p.id=v.province_id where v.layer='states' and v.category_id=c.id and p.kind='land'),
        'taxes',(select coalesce(sum(p.taxes),0) from fauxlore.province_values v join fauxlore.provinces p on p.id=v.province_id where v.layer='states' and v.category_id=c.id and p.kind='land'),
        'provinces',coalesce((
          select jsonb_agg(jsonb_build_object(
            'id',p.id,'name',p.name,'kind',p.kind,'province_type',p.province_type,
            'population',p.population,'belonging',p.belonging,'control',p.control,
            'taxes',p.taxes,'production',p.production,
            'race',(select rc.name from fauxlore.province_values rv join fauxlore.map_categories rc on rc.layer=rv.layer and rc.id=rv.category_id where rv.province_id=p.id and rv.layer='races'),
            'religion',(select rc.name from fauxlore.province_values rv join fauxlore.map_categories rc on rc.layer=rv.layer and rc.id=rv.category_id where rv.province_id=p.id and rv.layer='religions'),
            'resource',(select rc.name from fauxlore.province_values rv join fauxlore.map_categories rc on rc.layer=rv.layer and rc.id=rv.category_id where rv.province_id=p.id and rv.layer='resources')
          ) order by p.id)
          from fauxlore.province_values v join fauxlore.provinces p on p.id=v.province_id
          where v.layer='states' and v.category_id=c.id and p.kind='land'
        ),'[]'::jsonb)
      ) as item
      from fauxlore.account_states ast
      join fauxlore.map_categories c on c.layer='states' and c.id=ast.state_id
      left join fauxlore.state_profiles sp on sp.state_id=c.id
      where ast.account_id=a.id
    ) owned;
    return result;
  end if;

  if path !~ '^admin/states/[0-9]+$' or method<>'DELETE' then
    raise sqlstate '22023' using message='Некорректный запрос';
  end if;
  if a.role<>'admin' then
    raise sqlstate '42501' using message='Нужна роль администратора';
  end if;
  if request_id is null then raise sqlstate '22023' using message='Нужен идентификатор команды'; end if;
  if body<>'{}'::jsonb then raise sqlstate '22023' using message='Удаление государства не принимает параметры'; end if;

  state_value:=split_part(path,'/',3)::integer;
  fingerprint:=md5(jsonb_build_array(method,path,body)::text);
  perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
  select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=game_state_api.request_id;
  if found then
    if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if;
    return previous.result;
  end if;

  select name into state_name from fauxlore.map_categories where layer='states' and id=state_value for update;
  if not found then raise sqlstate 'P0002' using message='Государство не найдено'; end if;

  update fauxlore.map_markers set state_id=null where state_id=state_value;
  get diagnostics unlinked_markers=row_count;
  delete from fauxlore.province_values where layer='states' and category_id=state_value;
  get diagnostics removed_assignments=row_count;
  select count(*) into province_count from fauxlore.province_values where layer='states' and category_id=state_value;
  delete from fauxlore.account_states where layer='states' and state_id=state_value;
  delete from fauxlore.state_profiles where state_id=state_value;
  delete from fauxlore.map_categories where layer='states' and id=state_value;

  update fauxlore._settings set value_json=to_jsonb((value_json#>>'{}')::bigint+1) where key='data_revision';
  result:=jsonb_build_object('id',state_value,'name',state_name,'deleted',true,
    'removed_province_assignments',removed_assignments,'unlinked_markers',unlinked_markers,
    'remaining_assignments',province_count);
  insert into fauxlore.operations(account_id,request_id,fingerprint,result)
    values(a.id,game_state_api.request_id,fingerprint,result);
  return result;
end $$;

revoke all on function fauxlore.game_state_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.game_state_api(text,text,jsonb,uuid) to anon,authenticated;

create or replace function public.fauxlore_api(path text, method text default 'GET', body jsonb default '{}', request_id uuid default null)
returns jsonb
language sql
security invoker
set search_path=''
as $$
  select case
    when path='admin/states' then fauxlore.state_api(path,method,body,request_id)
    when path='my/states' or path like 'admin/states/%' then fauxlore.game_state_api(path,method,body,request_id)
    else fauxlore.api(path,method,body,request_id)
  end
$$;
revoke all on function public.fauxlore_api(text,text,jsonb,uuid) from public;
grant execute on function public.fauxlore_api(text,text,jsonb,uuid) to anon,authenticated;
notify pgrst, 'reload schema';
