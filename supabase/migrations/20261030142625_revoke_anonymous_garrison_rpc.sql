-- Garrison data is available only after the database identifies an account.
revoke execute on function public.garrison_api(text,integer,integer,jsonb) from anon;
