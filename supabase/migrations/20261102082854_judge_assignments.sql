create table fauxlore.judge_assignments (
 judge_id bigint not null references fauxlore.accounts(id) on delete cascade,
 player_id bigint not null references fauxlore.accounts(id) on delete cascade,
 created_by bigint not null references fauxlore.accounts(id), created_at timestamptz not null default now(),
 primary key (judge_id,player_id), check(judge_id<>player_id)
);
alter table fauxlore.judge_assignments enable row level security;
revoke all on fauxlore.judge_assignments from public,anon,authenticated;
create function fauxlore.judge_can_review(judge_key bigint,state_key integer) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from fauxlore.judge_assignments j
 join fauxlore.account_states s on s.account_id=j.player_id and s.layer='states'
 where j.judge_id=judge_key and s.state_id=state_key
 and not exists(select 1 from fauxlore.account_states own where own.account_id=judge_key and own.layer='states' and own.state_id=state_key))
$$;
revoke all on function fauxlore.judge_can_review(bigint,integer) from public,anon,authenticated;
create function public.judge_assignments_api(action text,payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor fauxlore.accounts; judge_key bigint; player_key bigint;
begin
 actor:=fauxlore.current_account();
 if coalesce(actor.role,'')<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
 if action='snapshot' then
  return jsonb_build_object('players',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nickname',nickname) order by nickname,id) from fauxlore.accounts where role='player'),'[]'::jsonb),
   'assignments',coalesce((select jsonb_agg(jsonb_build_object('judge_id',j.judge_id,'judge',a.nickname,'player_id',j.player_id,'player',b.nickname) order by a.nickname,b.nickname,j.judge_id,j.player_id) from fauxlore.judge_assignments j join fauxlore.accounts a on a.id=j.judge_id join fauxlore.accounts b on b.id=j.player_id),'[]'::jsonb));
 elsif action='assign' then
  judge_key:=nullif(payload->>'judge_id','')::bigint; player_key:=nullif(payload->>'player_id','')::bigint;
  if judge_key is null or player_key is null or judge_key=player_key or (select count(*) from fauxlore.accounts where id in (judge_key,player_key) and role='player')<>2 then raise sqlstate '22023' using message='Выберите двух разных пользователей-игроков'; end if;
  insert into fauxlore.judge_assignments(judge_id,player_id,created_by) values(judge_key,player_key,actor.id) on conflict do nothing;
  return jsonb_build_object('assigned',true);
 elsif action='remove' then
  delete from fauxlore.judge_assignments where judge_id=nullif(payload->>'judge_id','')::bigint and player_id=nullif(payload->>'player_id','')::bigint;
  if not found then raise sqlstate 'P0002' using message='Назначение не найдено'; end if;
  return jsonb_build_object('removed',true);
 end if;
 raise sqlstate '22023' using message='Неизвестное действие';
end $$;
revoke all on function public.judge_assignments_api(text,jsonb) from public,anon;
grant execute on function public.judge_assignments_api(text,jsonb) to authenticated;
notify pgrst,'reload schema';
