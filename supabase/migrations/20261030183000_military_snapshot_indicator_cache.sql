-- The snapshot used to recalculate the same state indicators six times while
-- constructing two identical leader-limit keys. Read them once per request.
do $migration$
declare fn text; marker text;
begin
  fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
  marker:='relation text;'||chr(10)||'begin';
  if position(marker in fn)=0 then raise exception 'Military API declarations changed'; end if;
  fn:=replace(fn,marker,'relation text; indicator_snapshot jsonb;'||chr(10)||'begin');
  marker:='if action=''snapshot'' then'||chr(10)||'  return jsonb_build_object(';
  if position(marker in fn)=0 then raise exception 'Military snapshot entry changed'; end if;
  fn:=replace(fn,marker,'if action=''snapshot'' then'||chr(10)||
    '  indicator_snapshot:=fauxlore.state_indicators(sid);'||chr(10)||
    '  return jsonb_build_object(');
  if length(fn)-length(replace(fn,'fauxlore.state_indicators(sid)',''))<>6*length('fauxlore.state_indicators(sid)')+length('fauxlore.state_indicators(sid)') then
    raise exception 'Military indicator references changed'; end if;
  -- Leave the new assignment intact and replace only the six expressions.
  fn:=replace(fn,'(fauxlore.state_indicators(sid)->>','(indicator_snapshot->>');
  execute fn;
end
$migration$;
notify pgrst,'reload schema';
