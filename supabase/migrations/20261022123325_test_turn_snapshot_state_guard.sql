-- Compare the actual turn-mutated tables instead of the global map revision.
-- The turn itself updates several state rows and legitimately advances that counter.
alter table fauxlore.turn_test_snapshot add column if not exists after_payload jsonb;

create or replace function fauxlore.turn_snapshot_payload()
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
    'state_profiles',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.state_profiles x),
    'state_group_politics',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.state_group_politics x),
    'state_characters',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.state_characters x),
    'state_succession_events',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.state_succession_events x),
    'state_birth_events',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.state_birth_events x),
    'notifications',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.notifications x),
    'state_treasuries',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.state_treasuries x),
    'state_treasury_debts',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.state_treasury_debts x),
    'state_budget_ledger',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.state_budget_ledger x),
    'turn_economy_reports',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.turn_economy_reports x),
    'game_calendar',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.game_calendar x)
  )
$$;
revoke all on function fauxlore.turn_snapshot_payload() from public,anon,authenticated;

-- Capture the current post-test state so the active test from this session remains reversible.
update fauxlore.turn_test_snapshot set after_payload=fauxlore.turn_snapshot_payload()
where singleton=true and after_revision is not null and after_payload is null;

do $$
declare fn text; old_capture text; new_capture text; old_guard text; new_guard text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.test_turn_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_capture:='update fauxlore.turn_test_snapshot set after_year=cal.year,after_turn=cal.turn,after_revision=revision where singleton=true;';
  new_capture:='update fauxlore.turn_test_snapshot set after_year=cal.year,after_turn=cal.turn,after_revision=revision,after_payload=fauxlore.turn_snapshot_payload() where singleton=true;';
  old_guard:='if (select coalesce((value_json#>>''{}'')::bigint,0) from fauxlore._settings where key=''live_revision'')<>snap.after_revision then'||chr(10)||
    '      raise sqlstate ''40001'' using message=''После тестового хода появились новые изменения. Откат отменён, чтобы их не затереть.''; end if;';
  new_guard:='if fauxlore.turn_snapshot_payload() is distinct from snap.after_payload then'||chr(10)||
    '      raise sqlstate ''40001'' using message=''После тестового хода появились изменения в игровых данных. Откат отменён, чтобы их не затереть.''; end if;';
  if position(old_capture in fn)=0 or position(old_guard in fn)=0 then raise exception 'Could not locate test-turn snapshot capture or revision guard'; end if;
  fn:=replace(replace(fn,old_capture,new_capture),old_guard,new_guard);
  execute fn;
end $$;
