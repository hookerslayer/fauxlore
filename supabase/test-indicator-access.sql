begin;
do $$
declare actor fauxlore.accounts; sid integer; other_sid integer;
begin
  select * into actor from fauxlore.accounts where role='admin' and auth_user_id is not null limit 1;
  if actor.id is null then raise exception 'A verified administrator is required'; end if;
  select min(state_id),max(state_id) into sid,other_sid from fauxlore.state_profiles;
  if sid=other_sid then raise exception 'Two states required for access tests'; end if;
  perform set_config('request.jwt.claim.sub',actor.auth_user_id::text,true);
  perform set_config('fauxlore.test_state',sid::text,true);
  perform set_config('fauxlore.test_other_state',other_sid::text,true);
  update fauxlore.accounts set role='player' where id=actor.id;
  delete from fauxlore.account_states where account_id=actor.id;
  insert into fauxlore.account_states(account_id,state_id) values(actor.id,sid);
end $$;
set local role authenticated;
do $$
declare base text:='states/'||current_setting('fauxlore.test_state')||'/indicators'; value jsonb;
begin
  value:=public.fauxlore_api('my/'||base,'GET','{}',null);
  if value->>'state_id'<>current_setting('fauxlore.test_state') then raise exception 'Assigned state read failed'; end if;
  begin
    perform public.fauxlore_api('my/'||base,'PATCH','{"development_limit":2000}',gen_random_uuid());
    raise exception 'Player changed development limit';
  exception when insufficient_privilege then null; end;
  begin
    perform public.fauxlore_api('admin/'||base,'GET','{}',null);
    raise exception 'Player accessed admin route';
  exception when insufficient_privilege then null; end;
  begin
    perform public.fauxlore_api('my/states/'||current_setting('fauxlore.test_other_state')||'/indicators','GET','{}',null);
    raise exception 'Player accessed another state';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'Player can read own state; other states and administration denied' result;
rollback;
