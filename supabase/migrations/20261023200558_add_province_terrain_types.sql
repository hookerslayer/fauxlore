-- Extend province terrain values; only forest and marsh have map textures.
alter table fauxlore.provinces
  drop constraint if exists provinces_terrain_type_check;
alter table fauxlore.provinces
  add constraint provinces_terrain_type_check
  check (terrain_type in ('forest','marsh','plains','hills','mountains','high_mountains'));

do $$
declare
  definition text;
  old_check text := 't not in (''forest'',''marsh'')';
  new_check text := 't not in (''forest'',''marsh'',''plains'',''hills'',''mountains'',''high_mountains'')';
begin
  definition:=replace(pg_get_functiondef('fauxlore.normalize(text,jsonb)'::regprocedure),chr(13),'');
  if position(new_check in definition)=0 then
    if position(old_check in definition)=0 then
      raise exception 'Could not find terrain validation in fauxlore.normalize';
    end if;
    execute replace(definition,old_check,new_check);
  end if;
end $$;
