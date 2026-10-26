create or replace function fauxlore.charge_garrison_before_turn()
returns trigger language plpgsql security definer set search_path='' as $function$
declare state_row record; troop_cost numeric; fort_cost numeric; total_cost numeric; closing_balance numeric;
begin
 if new.year=old.year and new.turn=old.turn then return new; end if;
 for state_row in select state_id from fauxlore.state_profiles order by state_id loop
   select coalesce(sum(round(u.quantity*c.upkeep*.4,2)),0) into troop_cost
     from fauxlore.garrison_units u join fauxlore.garrison_sites g on g.province_id=u.province_id
     join fauxlore.military_unit_catalog c on c.id=u.unit_id where g.state_id=state_row.state_id;
   total_cost:=fauxlore.garrison_upkeep(state_row.state_id);fort_cost:=total_cost-troop_cost;
   if total_cost<=0 then continue; end if;
   update fauxlore.state_treasuries set balance=balance-total_cost,updated_at=now()
     where state_id=state_row.state_id and estate='Корона';
   insert into fauxlore.garrison_charges(state_id,year,turn,troops,fortifications)
     values(state_row.state_id,old.year,old.turn,troop_cost,fort_cost);
   select coalesce(sum(balance),0) into closing_balance from fauxlore.state_treasuries where state_id=state_row.state_id;
   update fauxlore.state_profiles set treasury=closing_balance where state_id=state_row.state_id;
   update fauxlore.turn_economy_reports set report=(select jsonb_agg(case when (entry.value->>'id')::integer=state_row.state_id then
      entry.value||jsonb_build_object('garrison_upkeep',troop_cost,'fortification_upkeep',fort_cost,
       'army_upkeep',coalesce((entry.value->>'army_upkeep')::numeric,0)+total_cost,
       'army_upkeep_paid',coalesce((entry.value->>'army_upkeep_paid')::numeric,0)+total_cost,
       'closing_treasury',closing_balance,'tax_buckets',coalesce(entry.value->'tax_buckets','{}'::jsonb)||
         jsonb_build_object('Корона',(select balance from fauxlore.state_treasuries where state_id=state_row.state_id and estate='Корона')))
      else entry.value end order by entry.ord) from jsonb_array_elements(report) with ordinality entry(value,ord))
     where year=old.year and turn=old.turn;
 end loop;
 return new;
end $function$;
revoke all on function fauxlore.charge_garrison_before_turn() from public,anon,authenticated;
create trigger game_calendar_garrison_upkeep before update of year,turn on fauxlore.game_calendar
 for each row execute function fauxlore.charge_garrison_before_turn();

create or replace function fauxlore.complete_garrison_projects()
returns trigger language plpgsql security definer set search_path='' as $function$
declare project_row fauxlore.garrison_projects; marker_key bigint;
begin
 if new.year=old.year and new.turn=old.turn then return new; end if;
 for project_row in select * from fauxlore.garrison_projects where status='building' order by id for update loop
  if project_row.turns_remaining>1 then
   update fauxlore.garrison_projects set turns_remaining=turns_remaining-1 where id=project_row.id;
  else
   if project_row.kind='fort' then
    update fauxlore.garrison_sites set fort_level=project_row.target_level where province_id=project_row.province_id;
    if not exists(select 1 from fauxlore.map_markers where province_id=project_row.province_id and type='fortress') then
      insert into fauxlore.map_markers(province_id,x,y,type,name,state_id)
       select p.id,(p.center->>0)::double precision,(p.center->>1)::double precision,'fortress',
         case when project_row.target_level=1 then 'Форт ' else 'Крепость ' end||p.name,project_row.state_id
       from fauxlore.provinces p where p.id=project_row.province_id returning id into marker_key;
    end if;
   else
    update fauxlore.garrison_sites set wall_level=project_row.target_level where province_id=project_row.province_id;
   end if;
   update fauxlore.garrison_projects set status='completed',turns_remaining=1,
     completed_year=new.year,completed_turn=new.turn where id=project_row.id;
   insert into fauxlore.notifications(account_id,kind,title,message)
    select a.account_id,'garrison','Строительство завершено',
      case when project_row.kind='fort' then 'Крепость' else 'Городские стены' end||' в провинции '||p.name||' построены.'
    from fauxlore.account_states a join fauxlore.provinces p on p.id=project_row.province_id
    where a.state_id=project_row.state_id;
  end if;
 end loop;
 return new;
end $function$;
revoke all on function fauxlore.complete_garrison_projects() from public,anon,authenticated;
create trigger garrison_complete_on_turn after update of year,turn on fauxlore.game_calendar
 for each row execute function fauxlore.complete_garrison_projects();

do $migration$
declare definition text; marker text;
begin
 definition:=pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure);
 marker:='if exists(select 1 from fauxlore.colonization_missions m where m.province_id=target_key and m.status=''active'') then';
 if position(marker in definition)=0 then raise exception 'Colonization fort guard marker missing'; end if;
 definition:=replace(definition,marker,
  'if exists(select 1 from fauxlore.garrison_sites g where g.province_id=target_key and g.fort_level>0 and g.state_id<>state_key) then
    raise sqlstate ''22023'' using message=''Чужой форт защищает нейтральную провинцию от колонизации''; end if;'||E'\n  '||marker);
 marker:='roll_value+gold_bonus+recruit_bonus-path_penalty';
 if position(marker in definition)=0 then raise exception 'Colonization fort bonus marker missing'; end if;
 definition:=replace(definition,marker,
  'roll_value+gold_bonus+recruit_bonus-path_penalty+case when exists(select 1 from fauxlore.garrison_sites g where g.province_id=target_key and g.state_id=state_key and g.fort_level>0) then 10 else 0 end');
 execute definition;
 definition:=pg_get_functiondef('fauxlore.state_tax_rates_api(text,text,jsonb,uuid)'::regprocedure);
 marker:='+fauxlore.militia_crown_upkeep(state_key),';
 if position(marker in definition)=0 then raise exception 'Garrison forecast marker missing'; end if;
 execute replace(definition,marker,left(marker,length(marker)-1)||'+fauxlore.garrison_upkeep(state_key),');
end $migration$;
