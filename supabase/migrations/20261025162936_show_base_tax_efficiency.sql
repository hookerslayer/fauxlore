-- The state overview reports the shared baseline, not a province-weighted average.
create or replace function fauxlore.province_tax_efficiency_base()
returns numeric language sql immutable set search_path='' as $$
select .5::numeric
$$;
revoke all on function fauxlore.province_tax_efficiency_base() from public,anon,authenticated;

create or replace function fauxlore.province_tax_efficiency(province_type text)
returns numeric language sql immutable set search_path='' as $$
select case when adjustment is null then null
  else greatest(0::numeric,least(1::numeric,fauxlore.province_tax_efficiency_base()+adjustment)) end
from (select case province_type when 'Столичная' then .2::numeric
  when 'Городская' then .1::numeric when 'Регион' then -.2::numeric else null::numeric end adjustment) modifiers
$$;
revoke all on function fauxlore.province_tax_efficiency(text) from public,anon,authenticated;

do $migration$
declare fn text; marker text;
begin
  fn:=pg_get_functiondef('fauxlore.state_indicators(integer)'::regprocedure);
  marker:='''tax_efficiency'',fauxlore.state_tax_efficiency(target_state),';
  if position(marker in fn)=0 then raise exception 'Province-average tax efficiency marker not found'; end if;
  execute replace(fn,marker,'''base_tax_efficiency'',fauxlore.province_tax_efficiency_base(),');
end
$migration$;

notify pgrst,'reload schema';
