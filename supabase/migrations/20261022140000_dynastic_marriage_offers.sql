create table if not exists fauxlore.state_marriage_proposals (
  id bigint generated always as identity primary key,
  from_state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  to_state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  from_character_id bigint not null references fauxlore.state_characters(id) on delete cascade,
  to_character_id bigint not null references fauxlore.state_characters(id) on delete cascade,
  status text not null default 'pending' check(status in ('pending','accepted','declined')),
  created_by bigint not null references fauxlore.accounts(id),
  created_at timestamptz not null default now(),
  answered_at timestamptz,
  check(from_state_id<>to_state_id)
);
create unique index if not exists state_marriage_pending_pair_idx on fauxlore.state_marriage_proposals
  (least(from_state_id,to_state_id),greatest(from_state_id,to_state_id)) where status='pending';
create index if not exists state_marriage_to_pending_idx on fauxlore.state_marriage_proposals(to_state_id,created_at desc) where status='pending';
alter table fauxlore.state_marriage_proposals enable row level security;
revoke all on fauxlore.state_marriage_proposals from public,anon,authenticated;

create or replace function fauxlore.dynastic_marriage_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; proposal fauxlore.state_marriage_proposals; previous fauxlore.operations;
  proposal_id bigint; from_state integer; to_state integer; actor_state integer; from_ruler fauxlore.state_characters;
  to_ruler fauxlore.state_characters; from_profile fauxlore.state_profiles; to_profile fauxlore.state_profiles;
  calendar_row fauxlore.game_calendar; fingerprint text; result jsonb; lawful boolean; actor text; action text;
begin
  a:=fauxlore.current_account(); actor:=split_part(path,'/',1);
  if path not in ('my/marriage-offers') and path !~ '^(my|admin)/marriage-offers/[0-9]+/(accept|reject)$' then raise sqlstate '22023' using message='Некорректный запрос династического брака'; end if;
  if actor='admin' and a.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if path='my/marriage-offers' and method='GET' and body='{}'::jsonb then
    if a.role='admin' then
      return jsonb_build_object(
        'states',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'authority',sp.principles->>'authority') order by c.name) from fauxlore.map_categories c join fauxlore.state_profiles sp on sp.state_id=c.id where c.layer='states'),'[]'::jsonb),
        'targets',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'authority',sp.principles->>'authority','ruler',ch.name||' '||coalesce(ch.surname,'')) order by c.name)
          from fauxlore.map_categories c join fauxlore.state_profiles sp on sp.state_id=c.id left join fauxlore.state_characters ch on ch.state_id=c.id and ch.is_current_ruler and ch.alive where c.layer='states'),'[]'::jsonb),
        'incoming',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'from_state_id',p.from_state_id,'from_state',fc.name,'to_state_id',p.to_state_id,'to_state',tc.name,
          'from_ruler',fa.name||' '||coalesce(fa.surname,''),'to_ruler',ta.name||' '||coalesce(ta.surname,''),'created_at',p.created_at) order by p.created_at desc)
          from fauxlore.state_marriage_proposals p join fauxlore.map_categories fc on fc.layer='states' and fc.id=p.from_state_id join fauxlore.map_categories tc on tc.layer='states' and tc.id=p.to_state_id
          join fauxlore.state_characters fa on fa.id=p.from_character_id join fauxlore.state_characters ta on ta.id=p.to_character_id where p.status='pending'),'[]'::jsonb),
        'outgoing','[]'::jsonb);
    end if;
    return jsonb_build_object(
      'states',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'authority',sp.principles->>'authority') order by c.name)
        from fauxlore.account_states ast join fauxlore.map_categories c on c.layer=ast.layer and c.id=ast.state_id join fauxlore.state_profiles sp on sp.state_id=c.id where ast.account_id=a.id and ast.layer='states'),'[]'::jsonb),
      'targets',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'authority',sp.principles->>'authority','ruler',ch.name||' '||coalesce(ch.surname,'')) order by c.name)
        from fauxlore.map_categories c join fauxlore.state_profiles sp on sp.state_id=c.id join fauxlore.state_characters ch on ch.state_id=c.id and ch.is_current_ruler and ch.alive
        where c.layer='states' and not exists(select 1 from fauxlore.state_marriages m where m.ended_at_turn is null and ch.id in(m.character_a_id,m.character_b_id))),'[]'::jsonb),
      'incoming',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'from_state_id',p.from_state_id,'from_state',fc.name,'to_state_id',p.to_state_id,'to_state',tc.name,
        'from_ruler',fa.name||' '||coalesce(fa.surname,''),'to_ruler',ta.name||' '||coalesce(ta.surname,''),'created_at',p.created_at) order by p.created_at desc)
        from fauxlore.state_marriage_proposals p join fauxlore.account_states ast on ast.state_id=p.to_state_id and ast.layer='states' and ast.account_id=a.id
        join fauxlore.map_categories fc on fc.layer='states' and fc.id=p.from_state_id join fauxlore.map_categories tc on tc.layer='states' and tc.id=p.to_state_id
        join fauxlore.state_characters fa on fa.id=p.from_character_id join fauxlore.state_characters ta on ta.id=p.to_character_id where p.status='pending'),'[]'::jsonb),
      'outgoing',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'from_state_id',p.from_state_id,'from_state',fc.name,'to_state_id',p.to_state_id,'to_state',tc.name,
        'from_ruler',fa.name||' '||coalesce(fa.surname,''),'to_ruler',ta.name||' '||coalesce(ta.surname,''),'created_at',p.created_at) order by p.created_at desc)
        from fauxlore.state_marriage_proposals p join fauxlore.account_states ast on ast.state_id=p.from_state_id and ast.layer='states' and ast.account_id=a.id
        join fauxlore.map_categories fc on fc.layer='states' and fc.id=p.from_state_id join fauxlore.map_categories tc on tc.layer='states' and tc.id=p.to_state_id
        join fauxlore.state_characters fa on fa.id=p.from_character_id join fauxlore.state_characters ta on ta.id=p.to_character_id where p.status='pending'),'[]'::jsonb));
  end if;
  if path='my/marriage-offers' and method='POST' then
    if body-'from_state_id'-'to_state_id'<>'{}' or coalesce(body->>'from_state_id','') !~ '^\d+$' or coalesce(body->>'to_state_id','') !~ '^\d+$' or request_id is null then raise sqlstate '22023' using message='Выберите отправляющее и целевое государства'; end if;
    from_state:=(body->>'from_state_id')::integer; to_state:=(body->>'to_state_id')::integer;
    if from_state=to_state or not exists(select 1 from fauxlore.account_states ast where ast.account_id=a.id and ast.layer='states' and ast.state_id=from_state) then raise sqlstate '42501' using message='Нет доступа к отправляющему государству'; end if;
    fingerprint:=md5(jsonb_build_array(method,path,body)::text); perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
    select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=dynastic_marriage_api.request_id;
    if found then if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if; return previous.result; end if;
    select * into from_ruler from fauxlore.state_characters where state_id=from_state and is_current_ruler and alive for update;
    select * into to_ruler from fauxlore.state_characters where state_id=to_state and is_current_ruler and alive for update;
    if from_ruler.id is null or to_ruler.id is null then raise sqlstate '22023' using message='В одном из государств нет действующего правителя'; end if;
    if exists(select 1 from fauxlore.state_marriages m where m.ended_at_turn is null and (from_ruler.id in(m.character_a_id,m.character_b_id) or to_ruler.id in(m.character_a_id,m.character_b_id))) then raise sqlstate '22023' using message='Один из правителей уже состоит в браке'; end if;
    insert into fauxlore.state_marriage_proposals(from_state_id,to_state_id,from_character_id,to_character_id,created_by)
      values(from_state,to_state,from_ruler.id,to_ruler.id,a.id) returning * into proposal;
    result:=jsonb_build_object('proposal_id',proposal.id,'status',proposal.status);
    insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,request_id,fingerprint,result);
    insert into fauxlore.notifications(account_id,kind,title,message)
      select distinct ast.account_id,'marriage','Предложен династический брак',(select name from fauxlore.map_categories where layer='states' and id=from_state)||' предлагает брак между правителями.'
      from fauxlore.account_states ast where ast.state_id=to_state and ast.layer='states'
      union select ac.id,'marriage','Предложен династический брак',(select name from fauxlore.map_categories where layer='states' and id=from_state)||' предлагает брак между правителями.'
        from fauxlore.accounts ac where ac.role='admin' and not exists(select 1 from fauxlore.account_states ast where ast.state_id=to_state and ast.layer='states');
    return result;
  end if;
  if method='POST' and path ~ '^(my|admin)/marriage-offers/[0-9]+/(accept|reject)$' then
    proposal_id:=split_part(path,'/',3)::bigint; action:=split_part(path,'/',4);
    if body<>'{}' or request_id is null then raise sqlstate '22023' using message='Некорректная команда принятия предложения'; end if;
    fingerprint:=md5(jsonb_build_array(method,path,body)::text); perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
    select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=dynastic_marriage_api.request_id;
    if found then if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if; return previous.result; end if;
    select * into proposal from fauxlore.state_marriage_proposals where id=proposal_id and status='pending' for update;
    if not found then raise sqlstate 'P0002' using message='Предложение уже обработано или не найдено'; end if;
    if actor='admin' then actor_state:=proposal.to_state_id;
    else
      select ast.state_id into actor_state from fauxlore.account_states ast where ast.account_id=a.id and ast.layer='states' and ast.state_id=proposal.to_state_id limit 1;
      if actor_state is null then raise sqlstate '42501' using message='Только принимающее государство может ответить на предложение'; end if;
    end if;
    if action='reject' then
      update fauxlore.state_marriage_proposals set status='declined',answered_at=now() where id=proposal.id;
      result:=jsonb_build_object('status','declined');
    else
      select * into from_ruler from fauxlore.state_characters where id=proposal.from_character_id and alive and is_current_ruler for update;
      select * into to_ruler from fauxlore.state_characters where id=proposal.to_character_id and alive and is_current_ruler for update;
      if from_ruler.id is null or to_ruler.id is null then raise sqlstate '22023' using message='Состав правителей изменился; предложение больше нельзя принять'; end if;
      if exists(select 1 from fauxlore.state_marriages m where m.ended_at_turn is null and (from_ruler.id in(m.character_a_id,m.character_b_id) or to_ruler.id in(m.character_a_id,m.character_b_id))) then raise sqlstate '22023' using message='Один из правителей уже состоит в браке'; end if;
      select * into from_profile from fauxlore.state_profiles where state_id=proposal.from_state_id;
      select * into to_profile from fauxlore.state_profiles where state_id=proposal.to_state_id;
      lawful:=(from_profile.principles->>'authority'='Династия' and to_profile.principles->>'authority'='Династия');
      select * into calendar_row from fauxlore.game_calendar where singleton=true;
      insert into fauxlore.state_marriages(character_a_id,character_b_id,marriage_type,lawful_for_a,lawful_for_b,started_at_turn)
        values(from_ruler.id,to_ruler.id,'dynastic',lawful,lawful,calendar_row.turn);
      update fauxlore.state_profiles set prestige=prestige+10 where state_id in(proposal.from_state_id,proposal.to_state_id);
      update fauxlore.state_marriage_proposals set status='accepted',answered_at=now() where id=proposal.id;
      result:=jsonb_build_object('status','accepted','lawful_for_dynasty',lawful,'prestige_awarded',10);
    end if;
    insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,request_id,fingerprint,result);
    insert into fauxlore.notifications(account_id,kind,title,message)
      select distinct ast.account_id,'marriage',case action when 'accept' then 'Династический брак заключён' else 'Предложение брака отклонено' end,
        case action when 'accept' then 'Предложение о браке между государствами принято. Участники получили по 10 ОП.' else 'Предложение о браке между государствами отклонено.' end
      from fauxlore.account_states ast where ast.state_id in(proposal.from_state_id,proposal.to_state_id) and ast.layer='states'
      union select ac.id,'marriage',case action when 'accept' then 'Династический брак заключён' else 'Предложение брака отклонено' end,
        case action when 'accept' then 'Предложение о браке принято; участники получили по 10 ОП.' else 'Предложение о браке отклонено.' end
        from fauxlore.accounts ac where ac.role='admin' and not exists(select 1 from fauxlore.account_states ast where ast.state_id=proposal.to_state_id and ast.layer='states');
    return result;
  end if;
  raise sqlstate '22023' using message='Недопустимый запрос';
end $$;
revoke all on function fauxlore.dynastic_marriage_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.dynastic_marriage_api(text,text,jsonb,uuid) to authenticated;

create or replace function public.fauxlore_api(path text,method text default 'GET',body jsonb default '{}',request_id uuid default null)
returns jsonb language sql security invoker set search_path='' as $$
 select case
  when path='my/marriage-offers' or path ~ '^(my|admin)/marriage-offers/[0-9]+/(accept|reject)$' then fauxlore.dynastic_marriage_api(path,method,body,request_id)
  when path ~ '^(my|admin)/states/[0-9]+/abdicate$' then fauxlore.abdicate_api(path,method,body,request_id)
  when path ~ '^(my|admin)/states/[0-9]+/(succession(/events/[0-9]+/choose)?|politics|designate)$' then fauxlore.succession_api(path,method,body,request_id)
  when path ~ '^my/states/[0-9]+/(birth-events|birth-events/[0-9]+/name|marriage-candidates|marriages/local)$' then fauxlore.character_lifecycle_api(path,method,body,request_id)
  when path ~ '^(my|admin)/states/[0-9]+/characters$' then fauxlore.characters_api(path,method,body,request_id)
  when path='my/applications' and method='GET' then fauxlore.my_applications()
  when path='my/applications' and method='POST' then fauxlore.registration_api_with_surname(path,method,body,request_id)
  when path ~ '^admin/applications/[0-9]+$' and method='PATCH' then fauxlore.registration_api_with_surname(path,method,body,request_id)
  when path like 'my/applications' or path like 'admin/applications%' or path='notifications' or path like 'notifications/%' then fauxlore.registration_api(path,method,body,request_id)
  when path ~ '^my/applications/[0-9]+$' then fauxlore.application_details(path,method,body)
  when path ~ '^state-emblem/[0-9]+$' or path ~ '^admin/state-emblem/[0-9]+$' then fauxlore.state_emblem_api(path,method,body,request_id)
  when path='game/calendar' or path='admin/turn/advance' then fauxlore.turn_api(path,method,body,request_id)
  when path='admin/states' then fauxlore.state_api(path,method,body,request_id)
  when path='my/states' or path like 'admin/states/%' then fauxlore.game_state_api(path,method,body,request_id)
  else fauxlore.api(path,method,body,request_id) end
$$;
revoke all on function public.fauxlore_api(text,text,jsonb,uuid) from public;
grant execute on function public.fauxlore_api(text,text,jsonb,uuid) to anon,authenticated;
notify pgrst,'reload schema';
