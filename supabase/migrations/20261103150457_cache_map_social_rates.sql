-- Run inside a transaction: compare the complete server map before and after.
create temporary table map_social_baseline on commit drop as select fauxlore.map_payload_unfiltered() value;
do $migration$
declare fn text; old text; replacement text; kind text;
begin
 fn:=pg_get_functiondef('fauxlore.map_payload_unfiltered()'::regprocedure);
 old:='with state_tax_rates as materialized';
 if position(old in fn)=0 then raise exception 'map state cache hook missing'; end if;
 replacement:=$sql$with state_social_rates as materialized (
  select sp.state_id id, fauxlore.effective_social_rate(sp.state_id,'crime',sp.crime) crime,
    fauxlore.effective_social_rate(sp.state_id,'corruption',sp.corruption) corruption
  from fauxlore.state_profiles sp
), state_tax_rates as materialized$sql$;
 fn:=replace(fn,old,replacement);
 foreach kind in array array['crime','corruption'] loop
  old:=format('(select fauxlore.effective_social_rate(c.id,%L,sp.%s) from fauxlore.state_profiles sp where sp.state_id=c.id)',kind,kind);
  replacement:=format('(select r.%s from state_social_rates r where r.id=c.id)',kind);
  if (length(fn)-length(replace(fn,old,'')))/length(old)<>2 then raise exception 'map province social hook missing or ambiguous: %',kind; end if;
  fn:=replace(fn,old,replacement);
  old:=format('fauxlore.effective_social_rate(sp.state_id,%L,sp.%s)',kind,kind);
  -- One occurrence is the new materialized source; replace the category consumer only.
  if (length(fn)-length(replace(fn,old,'')))/length(old)<>2 then raise exception 'map category social hook missing or ambiguous: %',kind; end if;
  fn:=replace(fn,old,format('coalesce((select r.%s from state_social_rates r where r.id=sp.state_id),0.2)',kind));
  fn:=replace(fn,format('select sp.state_id id, coalesce((select r.%s from state_social_rates r where r.id=sp.state_id),0.2) %s',kind,kind),format('select sp.state_id id, fauxlore.effective_social_rate(sp.state_id,%L,sp.%s) %s',kind,kind,kind));
  fn:=replace(fn,format('    coalesce((select r.%s from state_social_rates r where r.id=sp.state_id),0.2) %s',kind,kind),format('    fauxlore.effective_social_rate(sp.state_id,%L,sp.%s) %s',kind,kind,kind));
 end loop;
 execute fn;
end $migration$;
do $verify$ begin
 if (select value from map_social_baseline) is distinct from fauxlore.map_payload_unfiltered() then raise exception 'map social parity check failed'; end if;
end $verify$;
notify pgrst,'reload schema';
