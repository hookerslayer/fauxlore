-- A neutral fort may also be built where this state can send a sea-colonization mission.
create or replace function fauxlore.neutral_fort_colonizable(state_key integer,target_key integer)
returns boolean language plpgsql stable security definer set search_path='' as $function$
declare graph jsonb; frontier integer[]:='{}'; next_frontier integer[]; visited integer[]:='{}';
 land_key integer; sea_key integer; neighbor_key integer; step integer;
begin
 if not exists(select 1 from fauxlore.provinces where id=target_key and kind='land')
  or exists(select 1 from fauxlore.province_values where province_id=target_key and layer='states')
  or exists(select 1 from fauxlore.colonization_missions where province_id=target_key and status='active')
  or exists(select 1 from fauxlore.garrison_sites where province_id=target_key and fort_level>0 and state_id<>state_key)
  then return false; end if;
 if (select count(*) from fauxlore.colonization_attempts a cross join fauxlore.game_calendar c
     where a.state_id=state_key and a.year=c.year and a.turn=c.turn)>=2
  or exists(select 1 from fauxlore.colonization_attempts a cross join fauxlore.game_calendar c
     where a.state_id=state_key and a.province_id=target_key and a.year=c.year and a.turn=c.turn)
  then return false; end if;
 select neighbors into graph from fauxlore.map_adjacency where singleton;
 if exists(select 1 from jsonb_array_elements_text(coalesce(graph->target_key::text,'[]'::jsonb)) n(value)
   join fauxlore.province_values v on v.province_id=n.value::integer and v.layer='states' and v.category_id=state_key
   join fauxlore.provinces p on p.id=v.province_id and p.kind='land') then return true; end if;
 if not exists(select 1 from fauxlore.military_formations f
   join fauxlore.military_leaders l on l.id=f.leader_id and l.domain='naval' and l.status<>'dead'
   join fauxlore.military_formation_units fu on fu.formation_id=f.id
   join fauxlore.military_unit_catalog u on u.id=fu.unit_id and u.domain='naval' and u.capacity>0
   where f.state_id=state_key and f.active and f.domain='naval'
    and not exists(select 1 from fauxlore.colonization_missions m where m.status='active' and m.fleet_id=f.id)
   group by f.id having sum(fu.quantity::bigint*u.capacity)>=50) then return false; end if;
 for land_key in select v.province_id from fauxlore.province_values v join fauxlore.provinces p on p.id=v.province_id
   where v.layer='states' and v.category_id=state_key and p.kind='land' loop
   for sea_key in select n.value::integer from jsonb_array_elements_text(coalesce(graph->land_key::text,'[]'::jsonb)) n(value)
     join fauxlore.provinces p on p.id=n.value::integer and p.kind='sea' loop
     if not sea_key=any(visited) then visited:=array_append(visited,sea_key);frontier:=array_append(frontier,sea_key);end if;
   end loop;
 end loop;
 for step in 1..40 loop
   if cardinality(frontier)=0 then return false; end if;
   next_frontier:='{}';
   foreach sea_key in array frontier loop
     if coalesce(graph->target_key::text,'[]'::jsonb) @> jsonb_build_array(sea_key) then return true; end if;
     if step<40 then
       for neighbor_key in select n.value::integer from jsonb_array_elements_text(coalesce(graph->sea_key::text,'[]'::jsonb)) n(value)
         join fauxlore.provinces p on p.id=n.value::integer and p.kind='sea' loop
         if not neighbor_key=any(visited) then visited:=array_append(visited,neighbor_key);next_frontier:=array_append(next_frontier,neighbor_key);end if;
       end loop;
     end if;
   end loop;
   frontier:=next_frontier;
 end loop;
 return false;
end $function$;
revoke all on function fauxlore.neutral_fort_colonizable(integer,integer) from public,anon,authenticated;

do $migration$
declare definition text; marker text;
begin
 definition:=pg_get_functiondef('public.garrison_api(text,integer,integer,jsonb)'::regprocedure);
 marker:='if not exists(select 1 from fauxlore.map_adjacency a
      join lateral jsonb_array_elements_text(a.neighbors->province_key::text) n(value) on true
      join fauxlore.province_values v on v.province_id=n.value::integer and v.layer=''states'' and v.category_id=sid
      join fauxlore.provinces ownp on ownp.id=v.province_id and ownp.kind=''land'' where a.singleton) then
      raise sqlstate ''22023'' using message=''Нейтральный форт строится рядом со своей землёй''; end if;';
 if position(marker in definition)=0 then raise exception 'Neutral fort access marker missing'; end if;
 execute replace(definition,marker,
  'if not fauxlore.neutral_fort_colonizable(sid,province_key) then
      raise sqlstate ''22023'' using message=''Форт можно построить только там, где доступна колонизация''; end if;');
end $migration$;
