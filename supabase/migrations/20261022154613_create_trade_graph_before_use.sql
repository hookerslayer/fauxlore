do $$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.clear_trade_interzone_after_budget(integer,integer)'::regprocedure),chr(13),'');
  old_fragment:=$old$  if adjacency is null then return; end if;
  truncate pg_temp.trade_graph_edges;$old$;
  new_fragment:=$new$  if adjacency is null then return; end if;
  create temporary table if not exists pg_temp.trade_graph_edges(a integer not null,b integer not null,primary key(a,b)) on commit drop;
  truncate pg_temp.trade_graph_edges;$new$;
  if position(old_fragment in fn)=0 then raise exception 'Could not locate trade graph table initialization'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $$;
