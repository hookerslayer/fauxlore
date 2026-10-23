-- Race/religion group statuses follow the state's registration identity.
alter table fauxlore.state_group_politics
  add column if not exists status_changed_year integer,
  add column if not exists status_changed_turn integer;

-- Official identity is fixed at registration; all other present groups begin
-- with non-interference. Preserve official IDs when a ruler changes.
update fauxlore.state_group_politics gp
set status=case
  when gp.group_type='race' and gp.group_key=sp.official_race_id::text then 'Официальная'
  when gp.group_type='religion' and gp.group_key=sp.official_religion_id::text then 'Официальная'
  else 'Невмешательство' end
from fauxlore.state_profiles sp
where sp.state_id=gp.state_id and gp.group_type in ('race','religion');

create or replace function fauxlore.ensure_state_group_politics(target_state integer)
returns void language plpgsql security definer set search_path='' as $$
begin
  insert into fauxlore.state_group_politics(state_id,group_type,group_key,status)
  select target_state,'estate',e.name,fauxlore.estate_status_for(target_state,e.name)
  from unnest(array['Корона','Знать','Духовенство','Горожане','Крестьяне']) e(name)
  on conflict(state_id,group_type,group_key) do update set status=excluded.status;
  insert into fauxlore.state_group_politics(state_id,group_type,group_key,status)
  select distinct target_state,v.layer,v.category_id::text,
    case when v.layer='races' and v.category_id=sp.official_race_id then 'Официальная'
         when v.layer='religions' and v.category_id=sp.official_religion_id then 'Официальная'
         else 'Невмешательство' end
  from fauxlore.state_profiles sp
  join fauxlore.province_values sv on sv.layer='states' and sv.category_id=target_state
  join fauxlore.province_values v on v.province_id=sv.province_id and v.layer in ('races','religions')
  where sp.state_id=target_state
  on conflict(state_id,group_type,group_key) do nothing;
end $$;
revoke all on function fauxlore.ensure_state_group_politics(integer) from public,anon,authenticated;

create or replace function fauxlore.apply_ruler_change_effects(target_state integer,new_race integer,new_religion integer)
returns void language plpgsql security definer set search_path='' as $$
begin
  perform fauxlore.ensure_state_group_politics(target_state);
  update fauxlore.state_group_politics
  set loyalty=case when loyalty<.5 then least(.5,loyalty+.10) when loyalty>.5 then greatest(.5,loyalty-.10) else .5 end
  where state_id=target_state;
end $$;
revoke all on function fauxlore.apply_ruler_change_effects(integer,integer,integer) from public,anon,authenticated;

do $$
declare fn text; signature regprocedure; pattern text;
begin
  foreach signature in array array[
    'fauxlore.resolve_ruler_succession()'::regprocedure,
    'fauxlore.start_ruler_succession()'::regprocedure
  ] loop
    fn:=pg_get_functiondef(signature);
    fn:=replace(fn,'official_race_id=new_character.race_id,official_religion_id=new_character.religion_id,','');
    fn:=replace(fn,'official_race_id=heir.race_id,official_religion_id=heir.religion_id,','');
    fn:=replace(fn,'official_race_id=designee.race_id,official_religion_id=designee.religion_id,','');
    execute fn;
  end loop;
end $$;

-- Status changes are actor-scoped, replay-safe commands. The official group is
-- immutable; a player can change each other present group once per turn for 10 OP.
create or replace function fauxlore.group_status_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; sid integer; group_kind text; group_id integer; status_value text;
  sp fauxlore.state_profiles; gp fauxlore.state_group_politics; cal fauxlore.game_calendar;
  prior fauxlore.operations; fp text; result jsonb; official_id integer; cost integer;
begin
  a:=fauxlore.current_account();
  if path !~ '^(my|admin)/states/[0-9]+/politics$' or method<>'PATCH' then raise sqlstate '22023' using message='Недопустимая команда статуса группы'; end if;
  sid:=split_part(path,'/',3)::integer;
  if split_part(path,'/',1)='admin' then
    if a.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  elsif not exists(select 1 from fauxlore.account_states ast where ast.account_id=a.id and ast.layer='states' and ast.state_id=sid) then
    raise sqlstate '42501' using message='Нет доступа к этому государству';
  end if;
  if request_id is null or jsonb_typeof(body) is distinct from 'object' or body-'group_type'-'group_id'-'status'<>'{}'
    or body->>'group_type' not in ('race','religion') or coalesce(body->>'group_id','') !~ '^\d+$'
    or body->>'status' not in ('Признание','Невмешательство','Ассимиляция','Истребление') then
    raise sqlstate '22023' using message='Укажите присутствующую расу/религию и допустимый статус';
  end if;
  group_kind:=body->>'group_type'; group_id:=(body->>'group_id')::integer; status_value:=body->>'status';
  fp:=md5(jsonb_build_array(method,path,body)::text);
  perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
  select * into prior from fauxlore.operations o where o.account_id=a.id and o.request_id=group_status_api.request_id;
  if found then if prior.fingerprint<>fp then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if; return prior.result; end if;
  perform fauxlore.ensure_state_group_politics(sid);
  select * into sp from fauxlore.state_profiles where state_id=sid for update;
  select * into cal from fauxlore.game_calendar where singleton;
  official_id:=case when group_kind='race' then sp.official_race_id else sp.official_religion_id end;
  if group_id=official_id then raise sqlstate '22023' using message='Статус официальной группы закреплён регистрацией'; end if;
  select * into gp from fauxlore.state_group_politics where state_id=sid and group_type=group_kind and group_key=group_id::text for update;
  if not found or not exists(select 1 from fauxlore.province_values sv join fauxlore.province_values gv on gv.province_id=sv.province_id
    where sv.layer='states' and sv.category_id=sid and gv.layer=case group_kind when 'race' then 'races' else 'religions' end and gv.category_id=group_id) then
    raise sqlstate '22023' using message='Эта группа отсутствует в государстве';
  end if;
  if gp.status=status_value then raise sqlstate '22023' using message='Этот статус уже установлен'; end if;
  if gp.status_changed_year=cal.year and gp.status_changed_turn=cal.turn and a.role<>'admin' then raise sqlstate '22023' using message='Эту группу уже меняли в текущем ходу'; end if;
  cost:=case when a.role='admin' then 0 else 10 end;
  if coalesce(sp.prestige,0)<cost then raise sqlstate '22023' using message='Для смены статуса нужно 10 ОП'; end if;
  update fauxlore.state_group_politics set status=status_value,status_changed_year=cal.year,status_changed_turn=cal.turn
    where state_id=sid and group_type=group_kind and group_key=group_id::text;
  if cost>0 then update fauxlore.state_profiles set prestige=prestige-cost where state_id=sid; end if;
  result:=jsonb_build_object('state_id',sid,'group_type',group_kind,'group_id',group_id,'status',status_value,'cost',cost,'year',cal.year,'turn',cal.turn);
  insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,request_id,fp,result);
  return result;
end $$;
revoke all on function fauxlore.group_status_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.group_status_api(text,text,jsonb,uuid) to authenticated;

-- Route PATCH for politics to its dedicated command handler; GET remains in succession_api.
do $$
declare fn text; marker text:='if path ~ ''^(my|admin)/states/[0-9]+/trade-duty$'' then';
begin
  fn:=pg_get_functiondef('public.fauxlore_api(text,text,jsonb,uuid)'::regprocedure);
  if position(marker in fn)=0 then raise exception 'API dispatcher marker missing'; end if;
  fn:=replace(fn,marker,'if path ~ ''^(my|admin)/states/[0-9]+/politics$'' and method=''PATCH'' then return fauxlore.group_status_api(path,method,body,request_id); end if;'||chr(10)||marker);
  execute fn;
end $$;
notify pgrst,'reload schema';
