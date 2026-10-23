do $$
declare fn text; marker text;
begin
  fn:=pg_get_functiondef('fauxlore.map_payload()'::regprocedure);
  marker:='''{}''::jsonb)) else ''{}''::jsonb end';
  if position(marker in fn)=0 then raise exception 'State-layer status map marker missing'; end if;
  fn:=replace(fn,marker,'''{}''::jsonb),''race_statuses'',coalesce((select jsonb_object_agg(group_key,status) from fauxlore.state_group_politics where state_id=c.id and group_type=''race''),''{}''::jsonb),'||
    '''religion_statuses'',coalesce((select jsonb_object_agg(group_key,status) from fauxlore.state_group_politics where state_id=c.id and group_type=''religion''),''{}''::jsonb),'||
    '''official_race_id'',(select official_race_id from fauxlore.state_profiles where state_id=c.id),'||
    '''official_religion_id'',(select official_religion_id from fauxlore.state_profiles where state_id=c.id)) else ''{}''::jsonb end');
  marker:='''{}''::jsonb)) end||jsonb_build_object(''application_pending''';
  if position(marker in fn)=0 then raise exception 'Occupation status map marker missing'; end if;
  fn:=replace(fn,marker,'''{}''::jsonb),''occupation_race_statuses'',coalesce((select jsonb_object_agg(group_key,status) from fauxlore.state_group_politics where state_id=c.id and group_type=''race''),''{}''::jsonb),'||
    '''occupation_religion_statuses'',coalesce((select jsonb_object_agg(group_key,status) from fauxlore.state_group_politics where state_id=c.id and group_type=''religion''),''{}''::jsonb)) end||jsonb_build_object(''application_pending''');
  execute fn;
end $$;
notify pgrst,'reload schema';
