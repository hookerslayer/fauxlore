-- The battle calculator reads a pending encounter from the database after
-- checking the caller's admin role. Browser credentials cannot call this RPC.
create or replace function public.naval_battle_source_api(battle_key bigint)
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('id',b.id,'domain',b.domain,'status',b.status,'participants',b.participants)
  from fauxlore.military_battles b where b.id=battle_key
$$;
revoke all on function public.naval_battle_source_api(bigint) from public,anon,authenticated;
grant execute on function public.naval_battle_source_api(bigint) to service_role;
