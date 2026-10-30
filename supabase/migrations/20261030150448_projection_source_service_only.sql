-- The projection worker needs the complete map to calculate market-wide
-- forecasts. Its raw source is never callable with a browser credential.
create or replace function public.projection_source_api()
returns jsonb language sql stable security definer set search_path='' as $$
  select fauxlore.map_payload_unfiltered()
$$;
revoke all on function public.projection_source_api() from public, anon, authenticated;
grant execute on function public.projection_source_api() to service_role;
