create or replace function public.colonization_api(action text, target_state integer, payload jsonb default '{}'::jsonb)
returns jsonb
language sql
security invoker
set search_path = pg_catalog, fauxlore
as $function$
  select fauxlore.colonization_api(action, target_state, coalesce(payload, '{}'::jsonb));
$function$;

revoke all on function public.colonization_api(text, integer, jsonb) from public, anon;
grant execute on function public.colonization_api(text, integer, jsonb) to authenticated;

notify pgrst, 'reload schema';
