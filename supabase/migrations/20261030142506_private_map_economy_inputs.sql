-- Keep state financial inputs out of the public map response. The client may
-- receive them only for a state it controls; an administrator may inspect all.
do $migration$
declare definition text;
begin
  if to_regprocedure('fauxlore.map_payload_unfiltered()') is null then
    definition := pg_get_functiondef('fauxlore.map_payload()'::regprocedure);
    definition := replace(definition, 'FUNCTION fauxlore.map_payload()',
      'FUNCTION fauxlore.map_payload_unfiltered()');
    if definition = pg_get_functiondef('fauxlore.map_payload()'::regprocedure) then
      raise exception 'Could not copy the map payload function';
    end if;
    execute definition;
  end if;
end
$migration$;

revoke all on function fauxlore.map_payload_unfiltered() from public, anon, authenticated;

create or replace function fauxlore.map_payload() returns jsonb
language plpgsql stable security definer set search_path='' as $function$
declare
  result jsonb := fauxlore.map_payload_unfiltered();
  account_row fauxlore.accounts;
  allowed_states integer[] := '{}'::integer[];
  provinces jsonb;
  categories jsonb;
begin
  if auth.uid() is not null then
    account_row := fauxlore.current_account();
    if account_row.role = 'admin' then return result; end if;
    select coalesce(array_agg(state_id), '{}'::integer[]) into allowed_states
    from fauxlore.account_states where account_id=account_row.id;
  end if;

  select coalesce(jsonb_agg(
    case when province->'layers'->'states' is null
      or (province->'layers'->'states'->>'id')::integer = any(allowed_states)
      then province
      else jsonb_set(province, '{layers,states}',
        coalesce(province->'layers'->'states','{}'::jsonb)
          - 'crime' - 'corruption' - 'estate_tax_rates', true)
    end
    - case when exists (
      select 1 from fauxlore.map_categories state
      where state.layer='states' and state.id=any(allowed_states)
        and lower(state.name)=lower(province->>'occupation')
    ) then '__none__' else 'occupation_estate_tax_rates' end
    - case when exists (
      select 1 from fauxlore.map_categories state
      where state.layer='states' and state.id=any(allowed_states)
        and lower(state.name)=lower(province->>'occupation')
    ) then '__none__' else 'occupation_crime' end
    - case when exists (
      select 1 from fauxlore.map_categories state
      where state.layer='states' and state.id=any(allowed_states)
        and lower(state.name)=lower(province->>'occupation')
    ) then '__none__' else 'occupation_corruption' end
    order by (province->>'id')::integer), '[]'::jsonb)
    into provinces from jsonb_array_elements(result->'provinces') province;

  select coalesce(jsonb_agg(
    case when (category->>'id')::integer = any(allowed_states)
      or category->>'layer'<>'states' then category
      else category - 'crime' - 'corruption' - 'estate_tax_rates' end
    order by category->>'layer', (category->>'id')::integer), '[]'::jsonb)
    into categories from jsonb_array_elements(result->'categories') category;

  return jsonb_set(jsonb_set(result,'{provinces}',provinces),'{categories}',categories);
end
$function$;

revoke all on function fauxlore.map_payload() from public, anon, authenticated;
