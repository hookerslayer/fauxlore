-- Allow automatic inter-zone market routes to cross sea provinces through ports.
do $$
declare
  fn text;
  old_fragment text;
  new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.clear_trade_interzone_after_budget(integer,integer)'::regprocedure),chr(13),'');
  old_fragment:=$old$join fauxlore.provinces a on a.id=entry.key::integer and a.kind='land'
    join fauxlore.provinces b on b.id=raw.value::integer and b.kind='land'$old$;
  new_fragment:=$new$join fauxlore.provinces a on a.id=entry.key::integer and a.kind in ('land','sea')
    join fauxlore.provinces b on b.id=raw.value::integer and b.kind in ('land','sea')
      and (a.kind=b.kind or exists(
        select 1 from fauxlore.map_markers port_marker
        where port_marker.type='port'
          and port_marker.province_id=case when a.kind='sea' then a.id else b.id end
      ))$new$;
  if position(old_fragment in fn)=0 then
    raise exception 'Could not locate land-only edge filters in inter-zone trade route search';
  end if;
  fn:=replace(fn,old_fragment,new_fragment);
  execute fn;
end $$;

notify pgrst,'reload schema';
