-- Reuse the authoritative loyalty calculation within one state-indicators call.
-- Existing entry points remain unchanged for all other callers.
create temporary table indicator_loyalty_baseline on commit drop as
select state_id, fauxlore.state_indicators(state_id) value from fauxlore.state_profiles;

do $migration$
declare
  fn text; old text; replacement text;
begin
  fn:=pg_get_functiondef('fauxlore.state_indicators_before_urbanization(integer)'::regprocedure);
  old:='CREATE OR REPLACE FUNCTION fauxlore.state_indicators_before_urbanization(target_state integer)';
  if position(old in fn)=0 then raise exception 'indicator base signature missing'; end if;
  fn:=replace(fn,old,'CREATE OR REPLACE FUNCTION fauxlore.state_indicators_base_cached_loyalties(target_state integer, cached_loyalties jsonb)');
  old:='loyalties as (select * from fauxlore.effective_estate_loyalties(target_state))';
  replacement:='loyalties as (select * from jsonb_to_recordset(cached_loyalties) as l(name text, status text, effective_loyalty numeric, influence numeric))';
  if position(old in fn)=0 then raise exception 'indicator base loyalty hook missing'; end if;
  execute replace(fn,old,replacement);
  revoke all on function fauxlore.state_indicators_base_cached_loyalties(integer,jsonb) from public,anon,authenticated;

  fn:=pg_get_functiondef('fauxlore.state_permanent_modifiers_for_display(integer)'::regprocedure);
  old:='CREATE OR REPLACE FUNCTION fauxlore.state_permanent_modifiers_for_display(target_state integer)';
  if position(old in fn)=0 then raise exception 'indicator display signature missing'; end if;
  fn:=replace(fn,old,'CREATE OR REPLACE FUNCTION fauxlore.state_modifiers_display_cached_loyalties(target_state integer, cached_loyalties jsonb)');
  old:='loyalty as materialized (select * from fauxlore.effective_estate_loyalties(target_state))';
  replacement:='loyalty as materialized (select * from jsonb_to_recordset(cached_loyalties) as l(name text, status text, effective_loyalty numeric, influence numeric))';
  if position(old in fn)=0 then raise exception 'indicator display loyalty hook missing'; end if;
  execute replace(fn,old,replacement);
  revoke all on function fauxlore.state_modifiers_display_cached_loyalties(integer,jsonb) from public,anon,authenticated;

  fn:=pg_get_functiondef('fauxlore.state_indicators(integer)'::regprocedure);
  old:=E'AS $function$\nselect fauxlore.state_indicators_before_urbanization(target_state)';
  replacement:=E'AS $function$\nwith cached_loyalties as materialized (select coalesce(jsonb_agg(to_jsonb(l)),''[]''::jsonb) value from fauxlore.effective_estate_loyalties(target_state) l)\nselect fauxlore.state_indicators_base_cached_loyalties(target_state,cache.value)';
  if position(old in fn)=0 then raise exception 'indicator function hook missing'; end if;
  fn:=replace(fn,old,replacement);
  old:='fauxlore.state_permanent_modifiers_for_display(target_state)';
  if position(old in fn)=0 then raise exception 'indicator display hook missing'; end if;
  fn:=replace(fn,old,'fauxlore.state_modifiers_display_cached_loyalties(target_state,cache.value)');
  old:='join fauxlore.state_profiles sp on sp.state_id=target_state';
  if position(old in fn)=0 then raise exception 'indicator state join missing'; end if;
  fn:=replace(fn,old,old||E'\ncross join cached_loyalties cache');
  execute fn;
end $migration$;

do $verify$
begin
  if exists(select 1 from indicator_loyalty_baseline b where b.value is distinct from fauxlore.state_indicators(b.state_id)) then
    raise exception 'state indicator parity check failed';
  end if;
end $verify$;
notify pgrst,'reload schema';
