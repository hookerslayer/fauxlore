do $migration$
declare
  definition text;
  list_marker text := '  if action=''list'' then';
  query_marker text := 'from (select * from fauxlore.wall_posts order by created_at desc,id desc limit';
  filter_action text := $snippet$  if action='filters' then
    return coalesce((select jsonb_agg(jsonb_build_object('key',q.key,'name',q.name) order by q.name,q.key) from (
      select distinct case when p.state_id is not null then 's:'||p.state_id::text else 'h:'||p.state_name end as key,
        coalesce(s.name,p.state_name) as name
      from fauxlore.wall_posts p left join fauxlore.map_categories s on s.layer='states' and s.id=p.state_id
      where p.state_id is not null or p.state_name is not null
    ) q where q.name is not null),'[]'::jsonb);
  end if;
$snippet$;
  filtered_query text := $snippet$from (select wp.* from fauxlore.wall_posts wp
        join fauxlore.accounts wa on wa.id=wp.account_id
        where coalesce(payload->>'filter','all')='all'
          or (payload->>'filter'='admin' and wa.role='admin')
          or (payload->>'filter'='state' and
              case when wp.state_id is not null then 's:'||wp.state_id::text else 'h:'||wp.state_name end = payload->>'state_key')
        order by wp.created_at desc,wp.id desc limit$snippet$;
begin
  definition:=pg_get_functiondef('fauxlore.wall_api(text,jsonb)'::regprocedure);
  if position(list_marker in definition)=0 or position(query_marker in definition)=0 then raise exception 'Wall filtering hooks missing'; end if;
  definition:=replace(definition,list_marker,filter_action||list_marker);
  definition:=replace(definition,query_marker,filtered_query);
  execute definition;
end $migration$;
notify pgrst,'reload schema';
