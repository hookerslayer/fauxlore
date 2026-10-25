do $$ declare fn text; old_fragment text; new_fragment text; begin
 fn:=pg_get_functiondef('fauxlore.military_actions_extra(text,integer,jsonb)'::regprocedure);
 old_fragment:='for amount in 1..fixed_points loop
   skill_name:=skill_names[floor(random()*4)::integer+1];';
 new_fragment:='for amount in 1..fixed_points loop
   if amount<=ceil(fixed_points/2.0) then
     if payload->>''estate'' in (''Знать'',''Крестьяне'') then
       skill_name:=skill_names[case when random()<.5 then 1 else 3 end];
     elsif payload->>''estate''=''Духовенство'' then
       skill_name:=skill_names[case when random()<.5 then 1 else 2 end];
     else
       skill_name:=skill_names[case when random()<.5 then 2 else 4 end];
     end if;
   else skill_name:=skill_names[floor(random()*4)::integer+1]; end if;';
 if position(old_fragment in fn)=0 then raise exception 'Leader dice marker missing'; end if;
 fn:=replace(fn,old_fragment,new_fragment);
 old_fragment:='if amount<>free_points then raise sqlstate ''22023'' using message=''Распределите все свободные очки''; end if;';
 new_fragment:='if amount<>free_points then raise sqlstate ''22023'' using message=''Распределите все свободные очки''; end if;
  select case when estate in (''Знать'',''Крестьяне'') then
      case when domain=''land'' then array[''Натиск'',''Маневренность''] else array[''Залп'',''Навигация''] end
    when estate=''Духовенство'' then
      case when domain=''land'' then array[''Натиск'',''Огонь''] else array[''Залп'',''Натиск''] end
    else case when domain=''land'' then array[''Огонь'',''Инженерные познания''] else array[''Натиск'',''Блокада''] end end
    into skill_names from fauxlore.military_leaders where id=leader_key;
  if (skills->>skill_names[1])::integer+(skills->>skill_names[2])::integer <
     ceil((select sum(value::integer) from jsonb_each_text(skills))/2.0) then
    raise sqlstate ''22023'' using message=''Не менее половины очков должно приходиться на профильные навыки сословия'';
  end if;';
 if position(old_fragment in fn)=0 then raise exception 'Leader origin validation marker missing'; end if;
 execute replace(fn,old_fragment,new_fragment);
end $$;
create unique index if not exists military_one_port_per_sea_province on fauxlore.map_markers(province_id) where type='port';
