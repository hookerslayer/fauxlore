-- PostgREST публикует только схему `public` (`db-schemas = "public"` в
-- vps/postgrest_production.conf), поэтому клиентские RPC должны быть объявлены
-- именно там. Тонкие обёртки делегируют реализацию в `fauxlore`, где остаются
-- все проверки прав и блокировки строк.
--
-- Без этих обёрток браузер получал бы 404 на /rpc/neutral_forces_api и
-- /rpc/admin_rollback_api, хотя сами функции уже существуют.

create or replace function public.neutral_forces_api(action text, payload jsonb default '{}'::jsonb)
returns jsonb language sql security definer set search_path='' as $function$
  select fauxlore.neutral_forces_api(action,payload)
$function$;
revoke all on function public.neutral_forces_api(text,jsonb) from public,anon;
grant execute on function public.neutral_forces_api(text,jsonb) to authenticated;

create or replace function public.admin_rollback_api(action text, payload jsonb default '{}'::jsonb)
returns jsonb language sql security definer set search_path='' as $function$
  select fauxlore.admin_rollback_api(action,payload)
$function$;
revoke all on function public.admin_rollback_api(text,jsonb) from public,anon;
grant execute on function public.admin_rollback_api(text,jsonb) to authenticated;
