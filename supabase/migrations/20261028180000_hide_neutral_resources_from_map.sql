-- Public map data reveals resource locations only for state-controlled
-- provinces. Administrators retain the complete resource layer.
do $migration$
declare definition text;
  old_fragment text := 'group by v.province_id)';
  new_fragment text := 'where (v.layer<>''resources'' or exists(select 1 from fauxlore.province_values owner'
    || ' where owner.province_id=v.province_id and owner.layer=''states'')'
    || ' or exists(select 1 from fauxlore.accounts account_row where account_row.auth_user_id=auth.uid()'
    || ' and account_row.role=''admin'')) group by v.province_id)';
begin
  definition:=pg_get_functiondef('fauxlore.map_payload()'::regprocedure);
  if position(old_fragment in definition)=0 then raise exception 'Map resource visibility hook missing'; end if;
  execute replace(definition,old_fragment,new_fragment);
end $migration$;
