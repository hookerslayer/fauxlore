-- Colonization chance is a percentage-point bonus/penalty applied to the final
-- result roll; the established investment, route and fortification rules remain.
do $migration$
declare fn text; marker text; replacement text;
begin
  fn:=pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure);
  marker:='-path_penalty+case when exists';
  replacement:='-path_penalty+floor(fauxlore.state_permanent_modifier_total(state_key,array[''colonization_chance''],null,null)*100)::integer+case when exists';
  if position(marker in fn)=0 then raise exception 'Colonization chance modifier insertion point missing'; end if;
  execute replace(fn,marker,replacement);
end
$migration$;

notify pgrst,'reload schema';
