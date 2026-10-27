-- Place newly created formations at the settlement or port where they are raised.
create or replace function fauxlore.military_spawn_coordinates(
  province_key integer,state_key integer,domain_key text
)
returns table(x double precision,y double precision)
language sql stable security definer set search_path='' as $function$
  select marker.x,marker.y
  from fauxlore.map_markers marker
  where marker.province_id=province_key
    and (domain_key='naval' and marker.type='port'
      or domain_key='land' and marker.type in ('capital','city'))
  order by case marker.type when 'capital' then 0 when 'city' then 1 when 'port' then 2 else 3 end,
    case when marker.state_id=state_key then 0 else 1 end,marker.id
  limit 1
$function$;
revoke all on function fauxlore.military_spawn_coordinates(integer,integer,text) from public,anon,authenticated;

create or replace function fauxlore.set_military_formation_position()
returns trigger language plpgsql security definer set search_path='' as $function$
declare center_value jsonb; spawn_x double precision; spawn_y double precision;
begin
  if new.position_x is null or new.position_y is null then
    if new.domain='naval' then
      select x,y into spawn_x,spawn_y
        from fauxlore.military_spawn_coordinates(new.province_id,new.state_id,new.domain);
      if spawn_x is null or spawn_y is null then
        raise sqlstate '22023' using message='Флотилию можно создать только в точке порта';
      end if;
    else
      select x,y into spawn_x,spawn_y
        from fauxlore.military_spawn_coordinates(new.province_id,new.state_id,new.domain);
      if spawn_x is null or spawn_y is null then
        select center into center_value from fauxlore.provinces where id=new.province_id;
        if not found then raise sqlstate '22023' using message='Провинция формирования не найдена'; end if;
        spawn_x:=(center_value->>0)::double precision;
        spawn_y:=(center_value->>1)::double precision;
      end if;
    end if;
    new.position_x:=coalesce(new.position_x,spawn_x);
    new.position_y:=coalesce(new.position_y,spawn_y);
  end if;
  return new;
end
$function$;
revoke all on function fauxlore.set_military_formation_position() from public,anon,authenticated;

-- A formation split stays at the source formation's exact map coordinate.
do $migration$
declare fn text; changed_fn text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.manage_formation_composition(text,integer,jsonb)'::regprocedure),chr(13),'');
  changed_fn:=regexp_replace(fn,
    'insert into fauxlore\.military_formations\(state_id,name,domain,province_id\)[[:space:]]+values\(sid,created_name,source_row\.domain,source_row\.province_id\) returning id into created_key;',
    'insert into fauxlore.military_formations(state_id,name,domain,province_id,position_x,position_y) values(sid,created_name,source_row.domain,source_row.province_id,source_row.position_x,source_row.position_y) returning id into created_key;');
  if changed_fn=fn then raise exception 'Could not preserve formation coordinates during split'; end if;
  execute changed_fn;
end
$migration$;
