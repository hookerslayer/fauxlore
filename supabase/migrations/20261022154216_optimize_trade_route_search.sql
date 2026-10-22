-- Keep the inter-zone shortest-route calculation linear in map edges.
do $$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.clear_trade_interzone_after_budget(integer,integer)'::regprocedure),chr(13),'');
  old_fragment:=$old$  create temporary table if not exists pg_temp.trade_route_frontier(province_id integer primary key,distance integer not null) on commit drop;
  create temporary table if not exists pg_temp.trade_route_seen(province_id integer primary key,distance integer not null) on commit drop;$old$;
  new_fragment:=$new$  create temporary table if not exists pg_temp.trade_route_frontier(province_id integer primary key,distance integer not null) on commit drop;
  create temporary table if not exists pg_temp.trade_route_next(province_id integer primary key,distance integer not null) on commit drop;
  create temporary table if not exists pg_temp.trade_route_seen(province_id integer primary key,distance integer not null) on commit drop;
  create temporary table if not exists pg_temp.trade_graph_edges(a integer not null,b integer not null,primary key(a,b)) on commit drop;$new$;
  if position(old_fragment in fn)=0 then raise exception 'Could not locate route search temp tables'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:=$old$  if adjacency is null then return; end if;$old$;
  new_fragment:=$new$  if adjacency is null then return; end if;
  truncate pg_temp.trade_graph_edges;
  insert into pg_temp.trade_graph_edges(a,b)
    select entry.key::integer,raw.value::integer
    from jsonb_each(adjacency) entry
    cross join lateral jsonb_array_elements_text(entry.value) raw(value)
    join fauxlore.provinces a on a.id=entry.key::integer and a.kind='land'
    join fauxlore.provinces b on b.id=raw.value::integer and b.kind='land'
    union
    select raw.value::integer,entry.key::integer
    from jsonb_each(adjacency) entry
    cross join lateral jsonb_array_elements_text(entry.value) raw(value)
    join fauxlore.provinces a on a.id=entry.key::integer and a.kind='land'
    join fauxlore.provinces b on b.id=raw.value::integer and b.kind='land'
  on conflict do nothing;$new$;
  if position(old_fragment in fn)=0 then raise exception 'Could not locate adjacency setup'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:=$old$      insert into pg_temp.trade_route_frontier
      select candidate.province_id,min(candidate.distance)
      from (
        select neighbor.id province_id,frontier.distance+1 distance
        from pg_temp.trade_route_frontier frontier
        join fauxlore.provinces current_province on current_province.id=frontier.province_id and current_province.kind='land'
        cross join lateral jsonb_array_elements_text(coalesce(adjacency->frontier.province_id::text,'[]'::jsonb)) raw(value)
        join fauxlore.provinces neighbor on neighbor.id=raw.value::integer and neighbor.kind='land'
        where not exists(select 1 from pg_temp.trade_route_seen seen where seen.province_id=neighbor.id)
        union all
        select neighbor.id,frontier.distance+1
        from pg_temp.trade_route_frontier frontier
        join fauxlore.provinces current_province on current_province.id=frontier.province_id and current_province.kind='land'
        join lateral jsonb_each(adjacency) entry(key,value) on true
        cross join lateral jsonb_array_elements_text(entry.value) raw(value)
        join fauxlore.provinces neighbor on neighbor.id=entry.key::integer and neighbor.kind='land'
        where raw.value::integer=frontier.province_id
          and not exists(select 1 from pg_temp.trade_route_seen seen where seen.province_id=neighbor.id)
      ) candidate group by candidate.province_id
      on conflict(province_id) do nothing;
      get diagnostics next_count=row_count;
      exit when next_count=0;
      insert into pg_temp.trade_route_seen select * from pg_temp.trade_route_frontier on conflict do nothing;$old$;
  new_fragment:=$new$      truncate pg_temp.trade_route_next;
      insert into pg_temp.trade_route_next
      select edge.b,frontier.distance+1
      from pg_temp.trade_route_frontier frontier join pg_temp.trade_graph_edges edge on edge.a=frontier.province_id
      where not exists(select 1 from pg_temp.trade_route_seen seen where seen.province_id=edge.b)
      group by edge.b,frontier.distance
      on conflict(province_id) do nothing;
      get diagnostics next_count=row_count;
      exit when next_count=0;
      insert into pg_temp.trade_route_seen select * from pg_temp.trade_route_next on conflict do nothing;
      truncate pg_temp.trade_route_frontier;
      insert into pg_temp.trade_route_frontier select * from pg_temp.trade_route_next;$new$;
  if position(old_fragment in fn)=0 then raise exception 'Could not locate route breadth-first expansion'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $$;
