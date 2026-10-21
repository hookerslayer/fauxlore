-- Add two unassigned resource categories without changing existing IDs or values.
do $$
declare
  resource record;
begin
  perform pg_advisory_xact_lock(hashtextextended('category:resources', 0));
  for resource in
    select * from (values
      ('Магическая пустошь', '#4b1f6f'),
      ('Эфемерная пустошь', '#163a5f')
    ) as additions(name, color)
  loop
    if not exists (
      select 1 from fauxlore.map_categories
      where layer = 'resources' and lower(name) = lower(resource.name)
    ) then
      insert into fauxlore.map_categories(layer, id, name, color)
      select 'resources', coalesce(max(id), 0) + 1, resource.name, resource.color
      from fauxlore.map_categories
      where layer = 'resources';
    end if;
  end loop;
end
$$;

update fauxlore._settings
set value_json = to_jsonb((value_json #>> '{}')::bigint + 1)
where key = 'data_revision';
