-- Records consensual dissolution; dynastic separation costs five prestige to the initiating state.
create or replace function fauxlore.marriage_dissolution_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  a fauxlore.accounts;
  state_value integer;
  marriage_value bigint;
  marriage_row fauxlore.state_marriages;
  character_a fauxlore.state_characters;
  character_b fauxlore.state_characters;
  state_row fauxlore.state_profiles;
  calendar_row fauxlore.game_calendar;
  previous fauxlore.operations;
  result jsonb;
  fingerprint text;
  cost_value numeric;
  message_value text;
begin
  if path !~ '^(my|admin)/states/[0-9]+/marriages(/[0-9]+/dissolve)?$' then
    raise sqlstate '22023' using message='Некорректный запрос о браке';
  end if;
  a:=fauxlore.current_account();
  state_value:=split_part(path,'/',3)::integer;

  if left(path,3)='my/' then
    if not exists(select 1 from fauxlore.account_states ast where ast.account_id=a.id and ast.layer='states' and ast.state_id=state_value) then
      raise sqlstate '42501' using message='Нет доступа к этому государству';
    end if;
  elsif a.role<>'admin' then
    raise sqlstate '42501' using message='Нужна роль администратора';
  end if;

  if path='my/states/'||state_value||'/marriages' or path='admin/states/'||state_value||'/marriages' then
    if method<>'GET' or body<>'{}'::jsonb then raise sqlstate '22023' using message='Недопустимый запрос'; end if;
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',m.id,'type',m.marriage_type,
      'character_a',concat_ws(' ',nullif(a.title,''),a.name,nullif(a.surname,'')),
      'character_b',concat_ws(' ',nullif(b.title,''),b.name,nullif(b.surname,'')),
      'state_a',coalesce((select c.name from fauxlore.map_categories c where c.layer='states' and c.id=a.state_id),'—'),
      'state_b',coalesce((select c.name from fauxlore.map_categories c where c.layer='states' and c.id=b.state_id),'—')
    ) order by m.id),'[]'::jsonb)
      into result
      from fauxlore.state_marriages m
      join fauxlore.state_characters a on a.id=m.character_a_id
      join fauxlore.state_characters b on b.id=m.character_b_id
      where m.ended_at_turn is null and (a.state_id=state_value or b.state_id=state_value);
    return result;
  end if;

  if method<>'POST' or body<>'{}'::jsonb or path !~ '/marriages/[0-9]+/dissolve$' then
    raise sqlstate '22023' using message='Недопустимый запрос';
  end if;
  if request_id is null then raise sqlstate '22023' using message='Нужен идентификатор команды'; end if;
  marriage_value:=split_part(path,'/',5)::bigint;
  fingerprint:=md5(jsonb_build_array(method,path,body)::text);
  perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
  select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=marriage_dissolution_api.request_id;
  if found then
    if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if;
    return previous.result;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('marriage-dissolve:'||marriage_value::text,0));
  select * into marriage_row from fauxlore.state_marriages m where m.id=marriage_value and m.ended_at_turn is null for update;
  if not found then raise sqlstate 'P0002' using message='Активный брак не найден'; end if;
  select * into character_a from fauxlore.state_characters where id=marriage_row.character_a_id;
  select * into character_b from fauxlore.state_characters where id=marriage_row.character_b_id;
  if state_value not in (character_a.state_id,character_b.state_id) then
    raise sqlstate '42501' using message='Это государство не является участником брака';
  end if;

  select * into state_row from fauxlore.state_profiles where state_id=state_value for update;
  if not found then raise sqlstate 'P0002' using message='Государство не найдено'; end if;
  cost_value:=case when marriage_row.marriage_type='dynastic' then 5 else 0 end;
  if state_row.prestige<cost_value then raise sqlstate '22023' using message='Для расторжения династического брака требуется 5 ОП'; end if;
  select * into calendar_row from fauxlore.game_calendar where singleton=true;
  if not found then raise sqlstate 'P0002' using message='Игровой календарь не найден'; end if;

  update fauxlore.state_marriages set ended_at_turn=calendar_row.turn where id=marriage_value and ended_at_turn is null;
  if not found then raise sqlstate '40001' using message='Брак уже был расторгнут'; end if;
  if cost_value>0 then update fauxlore.state_profiles set prestige=prestige-cost_value where state_id=state_value; end if;

  message_value:=format('Брак между %s %s и %s %s расторгнут%s.',character_a.name,character_a.surname,character_b.name,character_b.surname,
    case when cost_value>0 then ' за 5 ОП' else '' end);
  insert into fauxlore.notifications(account_id,kind,title,message)
    select distinct ast.account_id,'marriage','Брак расторгнут',message_value
    from fauxlore.account_states ast
    where ast.layer='states' and ast.state_id in(character_a.state_id,character_b.state_id);

  result:=jsonb_build_object('dissolved',true,'marriage_id',marriage_value,'type',marriage_row.marriage_type,'cost',cost_value);
  insert into fauxlore.operations(account_id,request_id,fingerprint,result)
    values(a.id,marriage_dissolution_api.request_id,fingerprint,result);
  return result;
end $$;
revoke all on function fauxlore.marriage_dissolution_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.marriage_dissolution_api(text,text,jsonb,uuid) to authenticated;

do $$
declare fn text; anchor text; replacement text;
begin
  select pg_get_functiondef('public.fauxlore_api(text,text,jsonb,uuid)'::regprocedure) into fn;
  anchor:=' elsif path=''my/marriage-offers'' or path ~ ''^(my|admin)/marriage-offers/[0-9]+/(accept|reject)$'' then return fauxlore.dynastic_marriage_api(path,method,body,request_id);';
  replacement:=' elsif path ~ ''^(my|admin)/states/[0-9]+/marriages(/[0-9]+/dissolve)?$'' then return fauxlore.marriage_dissolution_api(path,method,body,request_id);'||anchor;
  if position('fauxlore.marriage_dissolution_api' in fn)=0 then
    if position(anchor in fn)=0 then raise exception 'Could not find marriage API dispatch anchor'; end if;
    fn:=replace(fn,anchor,replacement);
    execute fn;
  end if;
end $$;
notify pgrst,'reload schema';
