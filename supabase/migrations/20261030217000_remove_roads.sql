do $migration$ declare fn text; start_pos integer; end_pos integer; begin
  fn:=pg_get_functiondef('fauxlore.map_payload_unfiltered()'::regprocedure);
  start_pos:=strpos(fn,'''roads'',coalesce(');
  end_pos:=strpos(fn,'''categories'',coalesce(');
  if start_pos=0 or end_pos<=start_pos then raise exception 'Map road payload not found'; end if;
  execute substr(fn,1,start_pos-1)||substr(fn,end_pos);

  fn:=pg_get_functiondef('fauxlore.api(text,text,jsonb,uuid)'::regprocedure);
  start_pos:=strpos(fn,'  elsif path=''admin/roads'' and method=''POST'' then');
  end_pos:=start_pos+strpos(substr(fn,start_pos),'  elsif path in (''admin/provinces/bulk-preview''')-1;
  if start_pos=0 or end_pos<=start_pos then raise exception 'Road API handlers not found'; end if;
  fn:=substr(fn,1,start_pos-1)||substr(fn,end_pos);
  fn:=replace(fn,' or path like ''admin/roads%''','');
  execute fn;
end $migration$;

create or replace function fauxlore.military_road_factor(x_value double precision,y_value double precision)
returns numeric language sql immutable security definer set search_path='' as $$ select 1::numeric $$;
drop function if exists fauxlore.create_road(jsonb,bigint);
drop table if exists fauxlore.map_roads;
notify pgrst,'reload schema';
