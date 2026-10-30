-- Return complete, server-validated trade previews and reuse the authoritative
-- military upkeep calculations in the national finance projection.
do $$
declare
  definition text;
  old_preview text;
  new_preview text;
  marker text;
  fiscal_definition text;
begin
  select pg_get_functiondef('fauxlore.trade_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  old_preview:=$old$    if path='my/trade-agreements/preview-route' then
      return jsonb_build_object('valid',true,'route_length',route_len,'route_limit',route_limit);
    end if;
    from_goods:=coalesce(body->'from_goods','[]'::jsonb);$old$;
  new_preview:=$new$    from_goods:=coalesce(body->'from_goods','[]'::jsonb);$new$;
  if position(old_preview in definition)=0 then
    raise exception 'Trade preview early-return block not found';
  end if;
  definition:=replace(definition,old_preview,new_preview);
  marker:=$m$    if from_gold>100000000000 or to_gold>100000000000 or (jsonb_array_length(from_goods)=0 and jsonb_array_length(to_goods)=0 and from_gold=0 and to_gold=0) then
      raise sqlstate '22023' using message='Укажите хотя бы один ресурс или денежный перевод'; end if;
    fingerprint:=md5(jsonb_build_array(method,path,body)::text);$m$;
  new_preview:=$n$    if from_gold>100000000000 or to_gold>100000000000 or (jsonb_array_length(from_goods)=0 and jsonb_array_length(to_goods)=0 and from_gold=0 and to_gold=0) then
      raise sqlstate '22023' using message='Укажите хотя бы один ресурс или денежный перевод'; end if;
    if path='my/trade-agreements/preview-route' then
      return jsonb_build_object(
        'valid',true,'route_length',route_len,'route_limit',route_limit,
        'proposal_cost',case when actor.role='admin' then 0 else
          fauxlore.permanent_prestige_action_cost(state_from,3)+
          floor(fauxlore.state_permanent_modifier_total(state_from,array['prestige_contract_cost'],null,null))::integer end,
        'available_prestige',(select coalesce(prestige,0) from fauxlore.state_profiles where state_id=state_from),
        'from_resources',(select coalesce(jsonb_agg(jsonb_build_object('name',e.value->>'name',
          'requested',e.value->>'quantity','available',greatest(0,fauxlore.trade_resource_surplus(state_from,e.value->>'name')))
          order by e.value->>'name'),'[]'::jsonb) from jsonb_array_elements(from_goods) e(value)),
        'to_resources',(select coalesce(jsonb_agg(jsonb_build_object('name',e.value->>'name',
          'requested',e.value->>'quantity','available',greatest(0,fauxlore.trade_resource_surplus(state_to,e.value->>'name')))
          order by e.value->>'name'),'[]'::jsonb) from jsonb_array_elements(to_goods) e(value)));
    end if;
    fingerprint:=md5(jsonb_build_array(method,path,body)::text);$n$;
  if position(marker in definition)=0 then
    raise exception 'Trade preview validation insertion point not found';
  end if;
  definition:=replace(definition,marker,new_preview);
  execute definition;

  select pg_get_functiondef('public.estate_fiscal_api(text,integer,jsonb)'::regprocedure) into fiscal_definition;
  marker:=$fiscal$'name',e.name,'balance',coalesce(t.balance,0),$fiscal$;
  new_preview:=$fiscal$'name',e.name,'balance',coalesce(t.balance,0),
       'max_investment',floor(least((select balance from fauxlore.state_treasuries where state_id=target_state and estate='Корона'),
         greatest(0,floor((1-coalesce(g.loyalty,.5))/case when e.name in ('Горожане','Крестьяне') then .01 else .005 end)*1000))/1000)*1000,
       'war_tax_amount',round(coalesce(t.balance,0)*.5,2),$fiscal$;
  if position(marker in fiscal_definition)=0 then raise exception 'Estate fiscal snapshot insertion point not found'; end if;
  execute replace(fiscal_definition,marker,new_preview);

  select pg_get_functiondef('fauxlore.army_budget_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  marker:=$army$'units',coalesce((select jsonb_agg(jsonb_build_object('name',t.name,'quantity',u.quantity,'upkeep_per_unit',t.upkeep_per_unit) order by t.name)$army$;
  new_preview:=$army$'forecast_upkeep',(select coalesce(sum(u.quantity*t.upkeep_per_unit),0)
        from fauxlore.state_army_units u join fauxlore.army_unit_types t on t.id=u.unit_type_id where u.state_id=state_value),
      'units',coalesce((select jsonb_agg(jsonb_build_object('name',t.name,'quantity',u.quantity,'upkeep_per_unit',t.upkeep_per_unit) order by t.name)$army$;
  if position(marker in definition)=0 then raise exception 'Army budget snapshot insertion point not found'; end if;
  definition:=replace(definition,marker,new_preview);
  execute definition;

end $$;

create or replace function fauxlore.military_upkeep_summary(target_state integer)
returns jsonb language plpgsql stable security definer set search_path='' as $function$
declare
  army_cost numeric:=0;
  fleet_cost numeric:=0;
  militia_cost numeric:=0;
  mercenary_cost numeric:=0;
  garrison_cost numeric:=0;
  militia_by_estate jsonb:=jsonb_build_object('Корона',0,'Знать',0,'Духовенство',0,'Горожане',0,'Крестьяне',0);
  garrison_by_estate jsonb;
  militia_row record;
  total_shares integer;
  burgher_cost integer;
  peasant_cost integer;
  noble_cost integer;
  crown_cost integer;
begin
  select coalesce(sum(cost) filter(where domain='land'),0),coalesce(sum(cost) filter(where domain='naval'),0)
    into army_cost,fleet_cost from (
      select f.id,f.domain,sum(u.upkeep*fauxlore.military_unit_cost_factor(target_state,u.id,'upkeep')*
        greatest(0,fu.quantity-case when u.name='Копейщик' then least(fu.quantity,coalesce(f.free_upkeep_quantity,0)) else 0 end)) cost
      from fauxlore.military_formations f
      join fauxlore.military_formation_units fu on fu.formation_id=f.id
      join fauxlore.military_unit_catalog u on u.id=fu.unit_id
      where f.state_id=target_state and f.active and f.kind='regular'
      group by f.id,f.domain
    ) formations;

  for militia_row in
    select mc.doctrine,mc.plan,
      floor(coalesce((select sum(fu.quantity::numeric*u.upkeep) from fauxlore.military_formation_units fu
        join fauxlore.military_unit_catalog u on u.id=fu.unit_id where fu.formation_id=mc.formation_id),0))::integer amount,
      floor(coalesce((select sum(fu.quantity::numeric*u.upkeep) from fauxlore.military_formation_units fu
        join fauxlore.military_unit_catalog u on u.id=fu.unit_id where fu.formation_id=mc.naval_formation_id),0))::integer naval_amount
    from fauxlore.militia_calls mc
    where mc.state_id=target_state and mc.status='active'
  loop
    militia_cost:=militia_cost+militia_row.amount+militia_row.naval_amount;
    burgher_cost:=0;peasant_cost:=0;noble_cost:=0;
    if militia_row.doctrine='Фирд' then
      total_shares:=coalesce((militia_row.plan#>>'{contributions,Горожане}')::integer,0)+
        coalesce((militia_row.plan#>>'{contributions,Крестьяне}')::integer,0);
      if total_shares>0 then
        burgher_cost:=floor(militia_row.amount*.6*
          coalesce((militia_row.plan#>>'{contributions,Горожане}')::integer,0)/total_shares);
        peasant_cost:=floor(militia_row.amount*.6*
          coalesce((militia_row.plan#>>'{contributions,Крестьяне}')::integer,0)/total_shares);
      end if;
    elsif militia_row.doctrine='Сословная армия' then
      noble_cost:=floor(militia_row.amount*.7);
    end if;
    crown_cost:=militia_row.amount+militia_row.naval_amount-burgher_cost-peasant_cost-noble_cost;
    militia_by_estate:=jsonb_set(militia_by_estate,'{Корона}',to_jsonb((militia_by_estate->>'Корона')::integer+crown_cost));
    militia_by_estate:=jsonb_set(militia_by_estate,'{Горожане}',to_jsonb((militia_by_estate->>'Горожане')::integer+burgher_cost));
    militia_by_estate:=jsonb_set(militia_by_estate,'{Крестьяне}',to_jsonb((militia_by_estate->>'Крестьяне')::integer+peasant_cost));
    militia_by_estate:=jsonb_set(militia_by_estate,'{Знать}',to_jsonb((militia_by_estate->>'Знать')::integer+noble_cost));
  end loop;

  select coalesce(sum(g.price*greatest(0,1+fauxlore.state_permanent_modifier_total(target_state,
    array['mercenary_upkeep'],null,null))),0) into mercenary_cost
  from fauxlore.military_formations f join fauxlore.mercenary_groups g on g.id=f.mercenary_group_id
  where f.state_id=target_state and f.active and f.kind='mercenary';
  garrison_cost:=fauxlore.garrison_upkeep(target_state);
  select coalesce(jsonb_object_agg(sponsor_estate,amount),'{}'::jsonb) into garrison_by_estate
  from (select g.sponsor_estate,sum(fauxlore.garrison_site_upkeep(g.province_id)) amount
    from fauxlore.garrison_sites g where g.state_id=target_state group by g.sponsor_estate) sponsored;
  return jsonb_build_object('army',army_cost,'fleet',fleet_cost,'militia',militia_cost,
    'mercenaries',mercenary_cost,'garrisons',garrison_cost,
    'garrison_by_estate',coalesce(garrison_by_estate,'{}'::jsonb),
    'militia_by_estate',militia_by_estate,
    'total',army_cost+fleet_cost+militia_cost+mercenary_cost+garrison_cost);
end
$function$;
revoke all on function fauxlore.military_upkeep_summary(integer) from public,anon,authenticated;

notify pgrst,'reload schema';
