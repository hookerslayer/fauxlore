-- PostgREST публикует только схему public, поэтому нужна обёртка
-- public.conquest_api, как у colonization_api.
do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to create conquest wrapper outside production candidate';
  end if;
end
$guard$;

create or replace function public.conquest_api(action text, target_state integer, payload jsonb default '{}'::jsonb)
returns jsonb
language sql
set search_path to 'pg_catalog', 'fauxlore'
as $fn$
  select fauxlore.conquest_api(action, target_state, coalesce(payload, '{}'::jsonb));
$fn$;

grant execute on function public.conquest_api(text, integer, jsonb) to authenticated;
