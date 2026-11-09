-- Исправление: счётчики ассимиляции допускают NULL, но не 0.
-- Заменяем неудачный сброс в функции завоевания.
do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to patch conquest outside production candidate';
  end if;
end
$guard$;

do $patch$
declare definition text;
begin
  select pg_get_functiondef('fauxlore.conquest_api(text,integer,jsonb)'::regprocedure) into definition;
  if position('race_assimilation_turns = 0' in definition) = 0
     and position('race_assimilation_turns = null' in definition) = 0 then
    raise exception 'Could not locate assimilation reset';
  end if;
  definition := replace(definition,
    'race_assimilation_turns = 0, race_assimilation_target_id = null,',
    'race_assimilation_turns = null, race_assimilation_target_id = null,');
  definition := replace(definition,
    'religion_assimilation_turns = 0, religion_assimilation_target_id = null,',
    'religion_assimilation_turns = null, religion_assimilation_target_id = null,');
  execute definition;
end
$patch$;
