-- Keep the existing state authorization and reuse the exact snapshot expressions.
do $migration$
declare fn text; first_pos integer; last_pos integer; fragment text; hook text; replacement text;
begin
 fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
 first_pos:=position('''states'',(select coalesce(jsonb_agg' in fn);
 last_pos:=position('''battles'',(select coalesce(jsonb_agg' in fn);
 if first_pos=0 or last_pos<=first_pos then raise exception 'military diplomacy snapshot hooks missing'; end if;
 fragment:=rtrim(substring(fn from first_pos for last_pos-first_pos), E' \t\r\n,');
 if position('''diplomacy'',' in fragment)=0 then raise exception 'military diplomacy data hook missing'; end if;
 hook:='elsif action=''upkeep_snapshot'' then';
 if (length(fn)-length(replace(fn,hook,'')))/length(hook)<>1 then raise exception 'military action hook missing or ambiguous'; end if;
 replacement:='elsif action=''diplomacy_snapshot'' then'||E'\n  return jsonb_build_object(''state_id'',sid,'||fragment||');'||E'\n '||hook;
 execute replace(fn,hook,replacement);
end $migration$;
notify pgrst,'reload schema';
