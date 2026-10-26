-- The map popup reads fortification levels for guests as well as players.
-- Mutating and state-wide actions still check current_account inside the RPC.
grant execute on function public.garrison_api(text,integer,integer,jsonb) to anon;
