-- Free skill points are distributed explicitly after the server-side rolls.
do $$ declare fn text; old_fragment text; new_fragment text; begin
 fn:=pg_get_functiondef('fauxlore.military_actions_extra(text,integer,jsonb)'::regprocedure);
 if position('skills jsonb; skill_names' in fn)=0 then raise exception 'Leader variable declaration missing'; end if;
 fn:=replace(fn,'skills jsonb; skill_names','skills jsonb; allocated_skills jsonb; skill_names');
 old_fragment:=' elsif action=''assign_leader'' then';
 new_fragment:=' elsif action=''allocate_leader'' then
  leader_key:=(payload->>''leader_id'')::bigint;
  select l.skills,coalesce((l.rolls->>''free_points'')::integer,0) into skills,free_points
    from fauxlore.military_leaders l where l.id=leader_key and l.state_id=sid and l.status=''active'' for update;
  if not found or free_points<1 then raise sqlstate ''22023'' using message=''Нет свободных очков навыков''; end if;
  if jsonb_typeof(payload->''allocation'')<>''object'' then raise sqlstate ''22023'' using message=''Укажите распределение навыков''; end if;
  amount:=0;
  for rec in select jsonb_build_object(''name'',key,''points'',value) from jsonb_each_text(payload->''allocation'') loop
    skill_name:=rec->>''name'';
    if not skills ? skill_name or (rec->>''points'')::integer<0 or (skills->>skill_name)::integer+(rec->>''points'')::integer>6 then
      raise sqlstate ''22023'' using message=''Недопустимое распределение навыков''; end if;
    amount:=amount+(rec->>''points'')::integer;
    skills:=jsonb_set(skills,array[skill_name],to_jsonb((skills->>skill_name)::integer+(rec->>''points'')::integer));
  end loop;
  if amount<>free_points then raise sqlstate ''22023'' using message=''Распределите все свободные очки''; end if;
  allocated_skills:=skills;
  update fauxlore.military_leaders set skills=allocated_skills,rolls=jsonb_set(rolls,''{free_points}'',''0''::jsonb) where id=leader_key;
  return jsonb_build_object(''skills'',allocated_skills);
 elsif action=''assign_leader'' then';
 if position(old_fragment in fn)=0 then raise exception 'Leader allocation insertion point missing'; end if;
 execute replace(fn,old_fragment,new_fragment);
 fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
 old_fragment:='''hire_leader'',''assign_leader''';new_fragment:='''hire_leader'',''allocate_leader'',''assign_leader''';
 if position(old_fragment in fn)=0 then raise exception 'Leader allocation dispatch marker missing'; end if;
 execute replace(fn,old_fragment,new_fragment);
end $$;
