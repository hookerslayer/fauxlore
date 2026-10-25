-- Seed the current recruit pool to the calculated cap for existing states,
-- and initialize new player states after their starting provinces are assigned.
DO $migration$
DECLARE
  fn text;
  marker text;
  replacement text;
BEGIN
  SELECT pg_get_functiondef('fauxlore.registration_api(text,text,jsonb,uuid)'::regprocedure)
  INTO fn;
  marker := 'where id=any(app.province_ids);'||E'\n'||'      select * into province_item from fauxlore.provinces where id=app.capital_province_id;';
  replacement := 'where id=any(app.province_ids);'||E'\n'||
    '      update fauxlore.state_profiles set recruits=greatest(0,coalesce((fauxlore.state_recruitment(state_value)->>''recruit_limit'')::integer,0)) where state_id=state_value;'||E'\n'||
    '      select * into province_item from fauxlore.provinces where id=app.capital_province_id;';
  IF fn IS NULL OR position(marker IN fn)=0 THEN
    RAISE EXCEPTION 'Could not locate state registration point after assigning starting provinces';
  END IF;
  fn := replace(fn,marker,replacement);

  marker := '''treasury'',15000,''prestige'',10,''recruits'',0,''recruit_limit'',null';
  replacement := '''treasury'',15000,''prestige'',10,''recruits'',(select recruits from fauxlore.state_profiles where state_id=state_value),''recruit_limit'',(fauxlore.state_recruitment(state_value)->>''recruit_limit'')::integer';
  IF position(marker IN fn)=0 THEN
    RAISE EXCEPTION 'Could not locate initial recruit values in registration_api response';
  END IF;
  fn := replace(fn,marker,replacement);
  EXECUTE fn;
END
$migration$;

-- Existing states receive a full reserve up to their current calculated cap.
UPDATE fauxlore.state_profiles p
SET recruits=greatest(0,coalesce((fauxlore.state_recruitment(p.state_id)->>'recruit_limit')::integer,0));

UPDATE fauxlore._settings
SET value_json=to_jsonb((value_json#>>'{}')::bigint+1)
WHERE key='data_revision';
