-- SQL wrapper plans both CASE branches; the function itself enforces admin.
grant execute on function fauxlore.state_api(text,text,jsonb,uuid) to anon;
