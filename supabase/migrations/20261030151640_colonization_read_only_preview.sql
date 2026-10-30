-- Reuse the attempt's authorization, resource and route checks for a read-only preview.
do $migration$
declare
  definition text;
  guard_marker text := 'if action<>''attempt'' or jsonb_typeof(payload) is distinct from ''object'' then';
  roll_marker text := 'roll_value:=floor(random()*101)::integer;';
begin
  definition := pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure);
  if position(guard_marker in definition)=0 or position(roll_marker in definition)=0 then
    raise exception 'Colonization preview insertion points changed';
  end if;
  definition := replace(definition, guard_marker,
    'if action not in (''attempt'',''preview'') or jsonb_typeof(payload) is distinct from ''object'' then');
  definition := replace(definition, roll_marker,
    'if action=''preview'' then
      gold_bonus:=least(15,greatest(0,((gold_value-gold_base)/1000)*5));
      recruit_bonus:=least(15,greatest(0,((recruits_value-50)/100)*5));
      return jsonb_build_object(''gold'',gold_value,''recruits'',recruits_value,
        ''gold_base'',gold_base,''gold_bonus'',gold_bonus,
        ''recruit_bonus'',recruit_bonus,''route_penalty'',path_penalty,
        ''sea'',sea_value,''province_id'',target_key);
    end if;
    ' || roll_marker);
  execute definition;
end
$migration$;
