-- Supabase denies changing session_replication_role from API functions.
-- Temporarily disable only user triggers on the snapshot tables while restoring.
do $$
declare fn text; old_disable text; new_disable text; old_enable text; new_enable text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.test_turn_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_disable:='perform set_config(''session_replication_role'',''replica'',true);';
  new_disable:='for t in select unnest(array[''state_profiles'',''state_group_politics'',''state_characters'',''state_succession_events'',''state_birth_events'',''notifications'',''state_treasuries'',''state_treasury_debts'',''state_budget_ledger'',''turn_economy_reports'',''game_calendar'']) loop execute format(''alter table fauxlore.%I disable trigger user'',t); end loop;';
  old_enable:='perform set_config(''session_replication_role'',''origin'',true);';
  new_enable:='for t in select unnest(array[''state_profiles'',''state_group_politics'',''state_characters'',''state_succession_events'',''state_birth_events'',''notifications'',''state_treasuries'',''state_treasury_debts'',''state_budget_ledger'',''turn_economy_reports'',''game_calendar'']) loop execute format(''alter table fauxlore.%I enable trigger user'',t); end loop;';
  if position(old_disable in fn)=0 or position(old_enable in fn)=0 then raise exception 'Could not locate trigger suppression statements in test_turn_api'; end if;
  fn:=replace(replace(fn,old_disable,new_disable),old_enable,new_enable);
  execute fn;
end $$;
