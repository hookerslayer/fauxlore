-- Keep the economic forecast aligned with the Crown's actual share.
create or replace function fauxlore.militia_crown_upkeep(state_key integer)
returns bigint language sql stable security definer set search_path='' as $function$
with active_call as (
  select m.*,floor(coalesce(sum(fu.quantity::numeric*u.upkeep),0))::bigint total_cost
  from fauxlore.militia_calls m
  join fauxlore.military_formations f on f.id=m.formation_id and f.active and f.kind='militia'
  left join fauxlore.military_formation_units fu on fu.formation_id=f.id
  left join fauxlore.military_unit_catalog u on u.id=fu.unit_id
  where m.state_id=state_key and m.status='active'
  group by m.state_id
)
select coalesce((select case
  when doctrine='Фирд' and
    coalesce((plan#>>'{contributions,Горожане}')::integer,0)+coalesce((plan#>>'{contributions,Крестьяне}')::integer,0)>0
  then total_cost
    -floor(total_cost*.6*coalesce((plan#>>'{contributions,Горожане}')::integer,0)
      /(coalesce((plan#>>'{contributions,Горожане}')::integer,0)+coalesce((plan#>>'{contributions,Крестьяне}')::integer,0)))::bigint
    -floor(total_cost*.6*coalesce((plan#>>'{contributions,Крестьяне}')::integer,0)
      /(coalesce((plan#>>'{contributions,Горожане}')::integer,0)+coalesce((plan#>>'{contributions,Крестьяне}')::integer,0)))::bigint
  when doctrine='Сословная армия' then total_cost-floor(total_cost*.7)::bigint
  else total_cost end from active_call),0)
$function$;
revoke all on function fauxlore.militia_crown_upkeep(integer) from public,anon,authenticated;

do $migration$
declare definition text; marker text;
begin
  definition:=pg_get_functiondef('fauxlore.state_tax_rates_api(text,text,jsonb,uuid)'::regprocedure);
  marker:='where f.state_id=state_key and f.active),';
  if position(marker in definition)=0 then raise exception 'Army forecast marker missing'; end if;
  execute replace(definition,marker,
    'where f.state_id=state_key and f.active and f.kind<>''militia'')+fauxlore.militia_crown_upkeep(state_key),');

  definition:=pg_get_functiondef('fauxlore.charge_militia_before_turn()'::regprocedure);
  marker:='''army_upkeep'',coalesce((entry.value->>''army_upkeep'')::numeric,0)+total_cost,';
  if position(marker in definition)=0 then raise exception 'Militia report marker missing'; end if;
  execute replace(definition,marker,marker||E'\n          ''army_upkeep_paid'',coalesce((entry.value->>''army_upkeep_paid'')::numeric,0)+total_cost,');

  definition:=pg_get_functiondef('public.militia_api(text,integer,jsonb)'::regprocedure);
  marker:='if call_row.status<>''active'' then';
  if position(marker in definition)=0 then raise exception 'Militia disband guard marker missing'; end if;
  execute replace(definition,marker,'if call_row.status is distinct from ''active'' then');
end $migration$;
