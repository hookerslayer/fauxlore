DO $migration$
DECLARE fn text; marker text; replacement text;
BEGIN
  fn:=pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure);
  marker:=$marker$  result_value:=jsonb_build_object($marker$;
  replacement:=$replacement$  insert into fauxlore.notifications(account_id,kind,title,message)
  select recipients.account_id,
    case when final_value>=40 then 'colonization_success' else 'colonization_attempt_failed' end,
    case when final_value>=40 then 'Колонизационная миссия началась' else 'Попытка колонизации провалилась' end,
    format('Попытка колонизации провинции %s завершилась %s. Итог броска: %s. Потери: %s рекрутов из %s. Потрачено: %s G.%s',
      p.name,
      case when final_value>=40 then 'успехом' else 'провалом' end,
      final_value,
      recruits_value-survivors,
      recruits_value,
      gold_value,
      case
        when sea_value and final_value<10 then ' Флотилия, корабли и экипаж потеряны.'
        when final_value>=40 then format(' Выжившие рекруты (%s) размещены в колонии и вернутся после завершения миссии.',survivors)
        when survivors>0 then format(' Выжившие рекруты (%s) вернулись в резерв.',survivors)
        else ''
      end)
  from (
    select distinct ast.account_id from fauxlore.account_states ast
      where ast.layer='states' and ast.state_id=state_key
    union
    select ac.id from fauxlore.accounts ac where ac.role='admin'
  ) recipients;

$replacement$||marker;
  IF position(marker IN fn)=0 THEN RAISE EXCEPTION 'Colonization result insertion point missing'; END IF;
  EXECUTE replace(fn,marker,replacement);
END
$migration$;
