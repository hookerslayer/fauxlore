-- Integer game outputs use floor consistently in province and state economy.
do $migration$
declare fn text; changed text;
begin
  fn:=pg_get_functiondef('fauxlore.province_estate_gross_tax(integer,integer,numeric,jsonb)'::regprocedure);
  changed:=replace(fn,'round(e.population::numeric*fauxlore.estate_tax_rate','floor(e.population::numeric*fauxlore.estate_tax_rate');
  changed:=replace(changed,'*greatest(0,least(1,share)),2)','*greatest(0,least(1,share)))');
  if changed=fn then raise exception 'Could not floor province estate tax'; end if;
  execute changed;

  fn:=pg_get_functiondef('fauxlore.state_tax_breakdown(numeric,numeric,numeric,jsonb)'::regprocedure);
  changed:=replace(fn,'round(gross*corruption*(cfg#>>''{stateEffects,corruptionTaxPenalty}'')::numeric,2)','floor(gross*corruption*(cfg#>>''{stateEffects,corruptionTaxPenalty}'')::numeric)');
  changed:=replace(changed,'round((gross-c.amount)*crime*(cfg#>>''{stateEffects,crimeTaxPenalty}'')::numeric,2)','floor((gross-c.amount)*crime*(cfg#>>''{stateEffects,crimeTaxPenalty}'')::numeric)');
  if changed=fn then raise exception 'Could not floor state tax deductions'; end if;
  execute changed;

  fn:=pg_get_functiondef('fauxlore.split_province_tax(numeric,text,text,jsonb)'::regprocedure);
  changed:=replace(fn,'round(gross*(1-greed),2)','floor(gross*(1-greed))');
  if changed=fn then raise exception 'Could not floor estate tax split'; end if;
  execute changed;

  fn:=pg_get_functiondef('fauxlore.state_recruitment(integer)'::regprocedure);
  changed:=replace(fn,'round(','floor(');
  changed:=replace(changed,'::numeric/100,0)),0),','::numeric/100)),0),');
  changed:=replace(changed,'::numeric/100,0)),0))','::numeric/100)),0))');
  if changed=fn then raise exception 'Could not floor recruitment outputs'; end if;
  execute changed;

  fn:=pg_get_functiondef('fauxlore.state_population_growth(integer)'::regprocedure);
  changed:=replace(fn,'round(p.population*.015','floor(p.population*.015');
  changed:=replace(changed,'''population''),0)),0) end value','''population''))),0) end value');
  if changed=fn then raise exception 'Could not floor population growth'; end if;
  execute changed;

  fn:=pg_get_functiondef('fauxlore.apply_turn_population_and_recruit_growth()'::regprocedure);
  changed:=replace(fn,'province_growth:=round(','province_growth:=floor(');
  changed:=replace(changed,'''population'),0)::integer;','''population'))::integer;');
  if changed=fn then raise exception 'Could not floor turn population growth'; end if;
  execute changed;
end
$migration$;
