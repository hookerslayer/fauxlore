-- Temporary, non-stacking estate loyalty support, paid from the estate's own treasury.
do $$ begin
 if exists(select 1 from fauxlore.turn_test_snapshot where singleton=true) then
   raise exception 'Rollback the active test turn before adding social spending'; end if;
end $$;
create table fauxlore.estate_social_actions (
  id bigint generated always as identity primary key,
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  estate text not null check (estate in ('Знать','Духовенство','Горожане','Крестьяне')),
  year integer not null,
  turn integer not null,
  cost numeric(14,2) not null check (cost>0),
  loyalty_bonus numeric(5,4) not null check (loyalty_bonus>0 and loyalty_bonus<=.1),
  turns_remaining smallint not null check (turns_remaining between 0 and 2),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index estate_social_one_active on fauxlore.estate_social_actions(state_id,estate) where active;
create index estate_social_state_history on fauxlore.estate_social_actions(state_id,id desc);
alter table fauxlore.estate_social_actions enable row level security;
revoke all on fauxlore.estate_social_actions from public,anon,authenticated;

create or replace function public.estate_social_api(action text,target_state integer,target_estate text default null)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; balance_value numeric; calendar_row fauxlore.game_calendar;
  social_row fauxlore.estate_social_actions; loyalty_before numeric; applied_bonus numeric;
begin
 actor:=fauxlore.current_account();
 if target_state is null or not exists(select 1 from fauxlore.state_profiles where state_id=target_state) then
   raise sqlstate '22023' using message='Выберите государство'; end if;
 if actor.role<>'admin' and not exists(select 1 from fauxlore.account_states
   where account_id=actor.id and state_id=target_state) then
   raise sqlstate '42501' using message='Нет доступа к государству'; end if;
 if action='start' then
   if target_estate not in ('Знать','Духовенство','Горожане','Крестьяне') or target_estate is null then
     raise sqlstate '22023' using message='Выберите сословие'; end if;
   perform 1 from fauxlore.state_profiles where state_id=target_state for update;
   if exists(select 1 from fauxlore.estate_social_actions where state_id=target_state
     and estate=target_estate and active) then
     raise sqlstate '22023' using message='Поддержка этого сословия ещё действует'; end if;
   select balance into balance_value from fauxlore.state_treasuries
     where state_id=target_state and estate=target_estate for update;
   if coalesce(balance_value,0)<2000 then
     raise sqlstate '22023' using message='У сословия недостаточно G'; end if;
   select * into calendar_row from fauxlore.game_calendar where singleton=true;
   insert into fauxlore.state_group_politics(state_id,group_type,group_key,status,loyalty)
     values(target_state,'estate',target_estate,fauxlore.estate_status_for(target_state,target_estate),.5)
     on conflict(state_id,group_type,group_key) do nothing;
   select loyalty into loyalty_before from fauxlore.state_group_politics
     where state_id=target_state and group_type='estate' and group_key=target_estate for update;
   applied_bonus:=least(.03,1-loyalty_before);
   if applied_bonus<=0 then raise sqlstate '22023' using message='Лояльность сословия уже максимальна'; end if;
   update fauxlore.state_group_politics set loyalty=least(1,loyalty+.03)
     where state_id=target_state and group_type='estate' and group_key=target_estate;
   update fauxlore.state_treasuries set balance=balance-2000,updated_at=now()
     where state_id=target_state and estate=target_estate;
   update fauxlore.state_profiles set treasury=(select coalesce(sum(balance),0)
     from fauxlore.state_treasuries where state_id=target_state) where state_id=target_state;
   insert into fauxlore.estate_social_actions(state_id,estate,year,turn,cost,loyalty_bonus,turns_remaining)
     values(target_state,target_estate,calendar_row.year,calendar_row.turn,2000,applied_bonus,2)
     returning * into social_row;
   return jsonb_build_object('id',social_row.id,'estate',target_estate,'cost',2000,
     'loyalty_bonus',applied_bonus,'turns_remaining',2);
 elsif action<>'snapshot' then
   raise sqlstate '22023' using message='Неизвестное действие поддержки сословия';
 end if;
 return jsonb_build_object('actions',(select coalesce(jsonb_agg(jsonb_build_object(
   'id',x.id,'estate',x.estate,'year',x.year,'turn',x.turn,'cost',x.cost,
   'bonus',x.loyalty_bonus,'turns_remaining',x.turns_remaining,'active',x.active)
   order by x.id desc),'[]'::jsonb) from
   (select * from fauxlore.estate_social_actions where state_id=target_state
     order by id desc limit 20) x));
end $function$;
revoke all on function public.estate_social_api(text,integer,text) from public,anon;
grant execute on function public.estate_social_api(text,integer,text) to authenticated;

create or replace function fauxlore.advance_estate_social_actions()
returns trigger language plpgsql security definer set search_path='' as $function$
declare action_row fauxlore.estate_social_actions;
begin
 if new.year=old.year and new.turn=old.turn then return new; end if;
 for action_row in select * from fauxlore.estate_social_actions where active order by id for update loop
   if action_row.turns_remaining<=1 then
     update fauxlore.state_group_politics set loyalty=greatest(0,loyalty-action_row.loyalty_bonus)
       where state_id=action_row.state_id and group_type='estate' and group_key=action_row.estate;
     update fauxlore.estate_social_actions set turns_remaining=0,active=false where id=action_row.id;
   else
     update fauxlore.estate_social_actions set turns_remaining=turns_remaining-1 where id=action_row.id;
   end if;
 end loop;
 return new;
end $function$;
revoke all on function fauxlore.advance_estate_social_actions() from public,anon,authenticated;
create trigger zzz_estate_social_after_turn after update of year,turn on fauxlore.game_calendar
  for each row execute function fauxlore.advance_estate_social_actions();

-- Admin test-turn rollback restores the social journal as well as the loyalty
-- and treasury values already present in the shared snapshot.
create or replace function fauxlore.capture_test_turn_estate_social()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
 new.payload:=coalesce(new.payload,'{}'::jsonb)||jsonb_build_object(
   'estate_social_actions',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]'::jsonb)
     from fauxlore.estate_social_actions x));
 return new;
end $function$;
revoke all on function fauxlore.capture_test_turn_estate_social() from public,anon,authenticated;
create trigger turn_test_snapshot_capture_estate_social before insert on fauxlore.turn_test_snapshot
  for each row execute function fauxlore.capture_test_turn_estate_social();

create or replace function fauxlore.restore_test_turn_estate_social()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
 if old.after_revision is null or jsonb_typeof(old.payload->'estate_social_actions')<>'array' then return old; end if;
 lock table fauxlore.estate_social_actions in access exclusive mode;
 delete from fauxlore.estate_social_actions where true;
 insert into fauxlore.estate_social_actions overriding system value
   select * from jsonb_populate_recordset(null::fauxlore.estate_social_actions,
     old.payload->'estate_social_actions');
 return old;
end $function$;
revoke all on function fauxlore.restore_test_turn_estate_social() from public,anon,authenticated;
create trigger turn_test_snapshot_restore_estate_social before delete on fauxlore.turn_test_snapshot
  for each row execute function fauxlore.restore_test_turn_estate_social();
notify pgrst,'reload schema';
