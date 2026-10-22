-- Expose only the compact revision token through a dedicated public RPC.
-- The general fauxlore_api wrapper also contains authenticated-only routes.
create or replace function public.map_revision_api()
returns jsonb language sql stable security definer set search_path='' as $$
  select fauxlore.map_revision()
$$;
revoke all on function public.map_revision_api() from public;
grant execute on function public.map_revision_api() to anon,authenticated;
notify pgrst,'reload schema';