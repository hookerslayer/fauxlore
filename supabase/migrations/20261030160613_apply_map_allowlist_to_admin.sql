-- Administrators receive the same province field allowlist as other clients.
-- Their state access is retained for editor screens and authorized projections.
do $$
declare
  definition text;
  old_branch text := 'if account_row.role = ''admin'' then return result - ''economy_config''; end if;
    select coalesce(array_agg(state_id), ''{}''::integer[]) into allowed_states
    from fauxlore.account_states where account_id=account_row.id;';
  new_branch text := 'if account_row.role = ''admin'' then
      select coalesce(array_agg(id), ''{}''::integer[]) into allowed_states
      from fauxlore.map_categories where layer=''states'';
    else
      select coalesce(array_agg(state_id), ''{}''::integer[]) into allowed_states
      from fauxlore.account_states where account_id=account_row.id;
    end if;';
begin
  select pg_get_functiondef('fauxlore.map_payload()'::regprocedure) into definition;
  if position(old_branch in definition)=0 then
    raise exception 'Admin map branch not found';
  end if;
  execute replace(definition,old_branch,new_branch);
end $$;
