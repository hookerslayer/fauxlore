-- finance_inputs is a VPS-only, already-authorized helper. The projection worker
-- consumes only prestige and estate buckets from its tax_rates field.
do $migration$
declare fn text; old text; n integer;
begin
 if to_regprocedure('fauxlore_vps_preview.finance_inputs(integer)') is null then return; end if;
 fn:=pg_get_functiondef('fauxlore_vps_preview.finance_inputs(integer)'::regprocedure);
 old:=$old$'tax_rates',fauxlore.state_tax_rates_api(prefix||'/states/'||target_state||'/tax-rates','GET','{}'::jsonb,NULL)$old$;
 n:=(length(fn)-length(replace(fn,old,'')))/length(old);
 if n=0 then
  old:=$old$'tax_rates', fauxlore.state_tax_rates_api(prefix || '/states/' || target_state || '/tax-rates', 'GET', '{}'::jsonb, NULL)$old$;
  n:=(length(fn)-length(replace(fn,old,'')))/length(old);
 end if;
 if n<>1 then raise exception 'finance tax input hook missing or ambiguous'; end if;
 fn:=replace(fn,old,$new$'tax_rates',(select jsonb_build_object('prestige',s.prestige,'buckets',coalesce((select jsonb_object_agg(t.estate,t.balance) from fauxlore.state_treasuries t where t.state_id=s.state_id),'{}'::jsonb)) from fauxlore.state_profiles s where s.state_id=target_state)$new$);
 old:='  RETURN jsonb_build_object(';
 if (length(fn)-length(replace(fn,old,'')))/length(old)<>1 then raise exception 'finance tax validation hook missing or ambiguous'; end if;
 fn:=replace(fn,old,$new$  IF NOT EXISTS (SELECT 1 FROM fauxlore.state_profiles WHERE state_id=target_state) THEN
    RAISE EXCEPTION 'Государство не найдено' USING ERRCODE='P0002';
  END IF;
  RETURN jsonb_build_object($new$);
 execute fn;
end $migration$;
notify pgrst,'reload schema';
