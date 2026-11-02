do $migration$
declare fn text; marker text := $old$*(1+fauxlore.state_permanent_modifier_total(state_row.state_id,array['population_growth','livestock_population_growth']$old$;
begin
 fn:=pg_get_functiondef('fauxlore.apply_turn_population_and_recruit_growth()'::regprocedure);
 if position(marker in fn)=0 then raise exception 'population multiplier hook missing'; end if;
 execute replace(fn,marker,$new$*greatest(0,1+fauxlore.state_permanent_modifier_total(state_row.state_id,array['population_growth','livestock_population_growth']$new$);
end $migration$;
notify pgrst,'reload schema';
