-- The existing public dispatcher invokes handlers as the authenticated role.
-- The handler checks the account and state assignment itself; internal
-- calculation helpers remain inaccessible to client roles.
grant execute on function fauxlore.state_indicators_api(text,text,jsonb,uuid) to authenticated;
notify pgrst,'reload schema';
