-- The public RPC dispatcher is SECURITY INVOKER, so authenticated callers
-- need execute permission on each routed API function.
grant execute on function fauxlore.estate_tax_rates_api(text,text,jsonb,uuid) to authenticated;
