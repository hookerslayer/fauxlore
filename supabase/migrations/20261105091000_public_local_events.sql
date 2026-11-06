-- Event listing is public; write actions still require an authorized account.
grant execute on function public.local_events_api(text,jsonb) to anon;
