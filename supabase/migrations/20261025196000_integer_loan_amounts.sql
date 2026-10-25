-- Loan principals and repayments are integer G amounts.
do $migration$
declare fn text; changed text;
begin
  fn:=pg_get_functiondef('fauxlore.state_estate_loans_api(text,text,jsonb,uuid)'::regprocedure);
  changed:=replace(fn,'amount_value<>round(amount_value,2)','amount_value<>trunc(amount_value)');
  changed:=replace(changed,'Сумма должна быть положительной, с точностью до 0,01 G','Сумма должна быть целым положительным числом G');
  if changed=fn then raise exception 'Could not require integer loan amounts'; end if;
  execute changed;
end
$migration$;
