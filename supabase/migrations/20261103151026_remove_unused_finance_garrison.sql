-- Deploy the updated projection worker before this migration: older workers
-- still request the garrison field from finance_inputs.
do $migration$
declare fn text; marker text; matches integer;
begin
 if to_regprocedure('fauxlore_vps_preview.finance_inputs(integer)') is null then return; end if;
 fn:=pg_get_functiondef('fauxlore_vps_preview.finance_inputs(integer)'::regprocedure);
 marker:=$old$'garrison',public.garrison_api('snapshot',target_state,NULL,'{}'::jsonb),$old$;
 matches:=(length(fn)-length(replace(fn,marker,'')))/length(marker);
 if matches=0 then
  marker:=$old$'garrison', public.garrison_api('snapshot', target_state, NULL, '{}'::jsonb),$old$;
  matches:=(length(fn)-length(replace(fn,marker,'')))/length(marker);
 end if;
 if matches<>1 then raise exception 'finance garrison hook missing or ambiguous'; end if;
 execute replace(fn,marker,'');
end $migration$;
notify pgrst,'reload schema';
