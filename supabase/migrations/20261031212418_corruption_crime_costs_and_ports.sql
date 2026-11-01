-- Cost inflation is applied after the existing unit/building modifiers.
create or replace function fauxlore.state_cost_multiplier(target_state integer)
returns numeric language sql stable security definer set search_path='' as $function$
  select 1+greatest(0,coalesce(sp.corruption,0))+greatest(0,coalesce(sp.crime,0))
  from fauxlore.state_profiles sp where sp.state_id=target_state
$function$;
revoke all on function fauxlore.state_cost_multiplier(integer) from public,anon,authenticated;

-- Test-turn rollback must restore generated-always battle identifiers too.
do $migration$
declare fn text; old_part text:=$s$'trade_market_settlements','trade_interzone_settlements') then$s$;
begin
  fn:=pg_get_functiondef('fauxlore.test_turn_api(text,text,jsonb,uuid)'::regprocedure);
  if position(old_part in fn)=0 then raise exception 'Test turn identity restoration changed'; end if;
  execute replace(fn,old_part,$s$'trade_market_settlements','trade_interzone_settlements','military_battles') then$s$);
  fn:=pg_get_functiondef('fauxlore.capture_test_turn_port_projects()'::regprocedure);
  if position('to_jsonb(x)' in fn)=0 then raise exception 'Test turn marker capture changed'; end if;
  execute replace(fn,'to_jsonb(x)','to_jsonb(x.*)');
end $migration$;

-- Automatic investment and estate-funded social spending are purchases, not
-- transfers between the crown and estate treasuries.
do $migration$
declare fn text; old_part text;
begin
  fn:=pg_get_functiondef('fauxlore.estate_investment_candidate(integer,text,integer,integer,integer)'::regprocedure);
  old_part:=$s$(1000+20*p.development)::integer$s$;
  if position(old_part in fn)=0 then raise exception 'Investment price changed'; end if;
  fn:=replace(fn,old_part,$s$floor((1000+20*p.development)*fauxlore.state_cost_multiplier(target_state))::integer$s$);
  old_part:=$s$(1000+20*p.development)<=available_g$s$;
  if position(old_part in fn)=0 then raise exception 'Investment budget condition changed'; end if;
  fn:=replace(fn,old_part,$s$floor((1000+20*p.development)*fauxlore.state_cost_multiplier(target_state))<=available_g$s$);
  execute fn;

  fn:=pg_get_functiondef('public.estate_social_api(text,integer,text)'::regprocedure);
  old_part:=$s$if coalesce(balance_value,0)<2000 then$s$;
  if position(old_part in fn)=0 then raise exception 'Estate social spending check changed'; end if;
  fn:=replace(fn,old_part,$s$if coalesce(balance_value,0)<floor(2000*fauxlore.state_cost_multiplier(target_state)) then$s$);
  fn:=replace(fn,$s$balance=balance-2000$s$,$s$balance=balance-floor(2000*fauxlore.state_cost_multiplier(target_state))$s$);
  fn:=replace(fn,$s$calendar_row.turn,2000,applied_bonus,2$s$,$s$calendar_row.turn,floor(2000*fauxlore.state_cost_multiplier(target_state)),applied_bonus,2$s$);
  fn:=replace(fn,$s$'estate',target_estate,'cost',2000,$s$,$s$'estate',target_estate,'cost',floor(2000*fauxlore.state_cost_multiplier(target_state)),$s$);
  old_part:=$s$return jsonb_build_object('actions',(select$s$;
  if position(old_part in fn)=0 then raise exception 'Estate social snapshot changed'; end if;
  fn:=replace(fn,old_part,$s$return jsonb_build_object('cost',floor(2000*fauxlore.state_cost_multiplier(target_state)),'actions',(select$s$);
  execute fn;
end $migration$;

-- Keep the legacy state resources forecast consistent with the military
-- breakdown returned to the financial screen.
do $migration$
declare fn text; first_pos integer; last_pos integer; marker text:=$s$'army_upkeep_forecast',$s$;
begin
  fn:=pg_get_functiondef('fauxlore.state_tax_rates_api(text,text,jsonb,uuid)'::regprocedure);
  first_pos:=position(marker in fn);
  last_pos:=position($s$'groups','[]'::jsonb$s$ in fn);
  if first_pos=0 or last_pos<=first_pos then raise exception 'State resources forecast changed'; end if;
  fn:=substring(fn from 1 for first_pos-1)||$s$'army_upkeep_forecast',(
    with summary as materialized (select fauxlore.military_upkeep_summary(state_key) value)
    select coalesce((value->>'army')::numeric,0)
      +coalesce((value->>'fleet')::numeric,0)
      +coalesce((value->>'mercenaries')::numeric,0)
      +coalesce((value#>>'{militia_by_estate,Корона}')::numeric,0)
      +coalesce((value#>>'{garrison_by_estate,Корона}')::numeric,0)
      +coalesce((value->>'ports')::numeric,0) from summary),
      $s$||substring(fn from last_pos);
  execute fn;
end $migration$;

-- Preserve the chosen expedition budget as the basis for its chance bonus;
-- the payment from the treasury includes the state cost multiplier.
do $migration$
declare fn text; old_part text;
begin
  fn:=pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure);
  old_part:=$s$if coalesce(crown_balance,0)<gold_value then$s$;
  if position(old_part in fn)=0 then raise exception 'Colonization balance check changed'; end if;
  fn:=replace(fn,old_part,$s$if coalesce(crown_balance,0)<floor(gold_value*fauxlore.state_cost_multiplier(state_key)) then$s$);
  old_part:=$s$balance=balance-gold_value,updated_at=now()$s$;
  if position(old_part in fn)=0 then raise exception 'Colonization payment changed'; end if;
  fn:=replace(fn,old_part,$s$balance=balance-floor(gold_value*fauxlore.state_cost_multiplier(state_key)),updated_at=now()$s$);
  fn:=replace(fn,$s$'gold_spent',gold_value$s$,$s$'gold_spent',floor(gold_value*fauxlore.state_cost_multiplier(state_key))$s$);
  old_part:=$s$      recruits_value,
      gold_value,
      case$s$;
  if position(old_part in fn)=0 then raise exception 'Colonization notification changed'; end if;
  fn:=replace(fn,old_part,$s$      recruits_value,
      floor(gold_value*fauxlore.state_cost_multiplier(state_key)),
      case$s$);
  fn:=replace(fn,$s$'gold',gold_value,'recruits',recruits_value$s$,$s$'gold',gold_value,'gold_cost',floor(gold_value*fauxlore.state_cost_multiplier(state_key)),'recruits',recruits_value$s$);
  old_part:=$s$'upkeep_paid',m.upkeep_paid,'route'$s$;
  if position(old_part in fn)=0 then raise exception 'Colonization snapshot changed'; end if;
  fn:=replace(fn,old_part,$s$'upkeep_paid',m.upkeep_paid,'upkeep_per_turn',floor(1000*fauxlore.state_cost_multiplier(m.state_id)),'route'$s$);
  execute fn;

  fn:=pg_get_functiondef('fauxlore.advance_colonization_missions()'::regprocedure);
  old_part:=$s$if coalesce(crown_balance,0)<1000 then$s$;
  if position(old_part in fn)=0 then raise exception 'Colonization upkeep check changed'; end if;
  fn:=replace(fn,old_part,$s$if coalesce(crown_balance,0)<floor(1000*fauxlore.state_cost_multiplier(m.state_id)) then$s$);
  fn:=replace(fn,$s$balance=balance-1000$s$,$s$balance=balance-floor(1000*fauxlore.state_cost_multiplier(m.state_id))$s$);
  fn:=replace(fn,$s$upkeep_paid=upkeep_paid+1000$s$,$s$upkeep_paid=upkeep_paid+floor(1000*fauxlore.state_cost_multiplier(m.state_id))$s$);
  fn:=replace(fn,$s$в казне не хватило 1 000 G на содержание$s$,$s$в казне не хватило средств на содержание$s$);
  execute fn;
end $migration$;

create or replace function fauxlore.garrison_site_upkeep(province_key integer)
returns numeric language sql stable security definer set search_path='' as $function$
with site as (
  select g.*,coalesce(g.state_id,owner.category_id) as modifier_state
  from fauxlore.garrison_sites g
  left join fauxlore.province_values owner on owner.province_id=g.province_id and owner.layer='states'
  where g.province_id=province_key
), base as (
  select coalesce((select sum(round(u.quantity*c.upkeep*.4,2)) from fauxlore.garrison_units u
      join fauxlore.military_unit_catalog c on c.id=u.unit_id where u.province_id=s.province_id),0) as troop_cost,
    greatest(0,(case s.fort_level when 1 then 100 when 2 then 200 when 3 then 300 when 4 then 400 else 0 end)
      -case when s.free_fort then 300 else 0 end)
    +greatest(0,(case s.wall_level when 1 then 300 when 2 then 500 when 3 then 700 else 0 end)
      -case when s.free_wall then 300 else 0 end) as fort_cost,
    s.modifier_state,s.province_id from site s
)
select floor(greatest(0,base.troop_cost)*(1+fauxlore.state_permanent_modifier_total(
    base.modifier_state,array['garrison_upkeep'],base.province_id,null))*fauxlore.state_cost_multiplier(base.modifier_state))
  +floor(greatest(0,base.fort_cost)*(1+fauxlore.state_permanent_modifier_total(
    base.modifier_state,array['fortification_upkeep'],null,null))*fauxlore.state_cost_multiplier(base.modifier_state))
from base
$function$;
revoke all on function fauxlore.garrison_site_upkeep(integer) from public,anon,authenticated;

create or replace function fauxlore.garrison_troop_upkeep(province_key integer)
returns numeric language sql stable security definer set search_path='' as $function$
select floor(coalesce((select sum(round(u.quantity*c.upkeep*.4,2)) from fauxlore.garrison_units u
  join fauxlore.military_unit_catalog c on c.id=u.unit_id where u.province_id=g.province_id),0)
  *greatest(0,1+fauxlore.state_permanent_modifier_total(g.state_id,array['garrison_upkeep'],g.province_id,null))
  *fauxlore.state_cost_multiplier(g.state_id))
from fauxlore.garrison_sites g where g.province_id=province_key
$function$;
revoke all on function fauxlore.garrison_troop_upkeep(integer) from public,anon,authenticated;

do $migration$
declare fn text; old_part text; new_part text;
begin
  fn:=pg_get_functiondef('fauxlore.charge_garrison_before_turn()'::regprocedure);
  old_part:=$s$select coalesce(sum(round(u.quantity*c.upkeep*.4,2)),0) into troop_cost
     from fauxlore.garrison_units u join fauxlore.garrison_sites g on g.province_id=u.province_id
     join fauxlore.military_unit_catalog c on c.id=u.unit_id where g.state_id=state_row.state_id$s$;
  new_part:=$s$select coalesce(sum(fauxlore.garrison_troop_upkeep(g.province_id)),0) into troop_cost
     from fauxlore.garrison_sites g where g.state_id=state_row.state_id$s$;
  if position(old_part in fn)=0 then raise exception 'Garrison settlement breakdown changed'; end if;
  execute replace(fn,old_part,new_part);
end $migration$;

-- Opolchenie amounts are calculated as an aggregate before sharing the bill
-- between estates; use the same rounding in the preview and settlement.
do $migration$
declare fn text; marker text;
begin
  fn:=pg_get_functiondef('fauxlore.militia_preview(integer)'::regprocedure);
  marker:=$s$  total_upkeep:=land_upkeep+naval_upkeep;$s$;
  if position(marker in fn)=0 then raise exception 'Militia preview changed'; end if;
  fn:=replace(fn,marker,$s$  land_upkeep:=floor(land_upkeep*fauxlore.state_cost_multiplier(state_key));
  naval_upkeep:=floor(naval_upkeep*fauxlore.state_cost_multiplier(state_key));
  total_upkeep:=land_upkeep+naval_upkeep;$s$);
  execute fn;

  fn:=pg_get_functiondef('fauxlore.charge_militia_before_turn()'::regprocedure);
  marker:=$s$    crown_cost:=total_cost;burgher_cost:=0;peasant_cost:=0;noble_cost:=0;$s$;
  if position(marker in fn)=0 then raise exception 'Militia settlement changed'; end if;
  fn:=replace(fn,marker,$s$    total_cost:=floor(total_cost*fauxlore.state_cost_multiplier(militia_row.state_id));
    fleet_cost:=floor(coalesce(fleet_cost,0)*fauxlore.state_cost_multiplier(militia_row.state_id));
$s$||marker);
  execute fn;

  fn:=pg_get_functiondef('fauxlore.military_upkeep_summary(integer)'::regprocedure);
  marker:=$s$    militia_cost:=militia_cost+militia_row.amount+militia_row.naval_amount;$s$;
  if position(marker in fn)=0 then raise exception 'Militia summary changed'; end if;
  fn:=replace(fn,marker,$s$    militia_row.amount:=floor(militia_row.amount*fauxlore.state_cost_multiplier(target_state));
    militia_row.naval_amount:=floor(militia_row.naval_amount*fauxlore.state_cost_multiplier(target_state));
$s$||marker);
  execute fn;

  fn:=pg_get_functiondef('fauxlore.militia_crown_upkeep(integer)'::regprocedure);
  marker:=$s$floor(coalesce(sum(fu.quantity::numeric*u.upkeep),0))::bigint$s$;
  if position(marker in fn)=0 then raise exception 'Militia crown upkeep changed'; end if;
  fn:=replace(fn,marker,$s$floor(coalesce(sum(fu.quantity::numeric*u.upkeep),0)*fauxlore.state_cost_multiplier(state_key))::bigint$s$);
  marker:=$s$floor(coalesce(sum(nfu.quantity::numeric*nu.upkeep),0))::bigint$s$;
  if position(marker in fn)=0 then raise exception 'Militia fleet crown upkeep changed'; end if;
  fn:=replace(fn,marker,$s$floor(coalesce(sum(nfu.quantity::numeric*nu.upkeep),0)*fauxlore.state_cost_multiplier(state_key))::bigint$s$);
  execute fn;
end $migration$;

-- The catalog, hire preview and regular formation cost all use this factor.
do $migration$
declare fn text; marker text:=$s$else array[]::text[] end,null,null))
from fauxlore.military_unit_catalog$s$;
begin
  fn:=pg_get_functiondef('fauxlore.military_unit_cost_factor(integer,bigint,text)'::regprocedure);
  if position(marker in fn)=0 then raise exception 'Military unit factor changed'; end if;
  execute replace(fn,marker,$s$else array[]::text[] end,null,null))*fauxlore.state_cost_multiplier(target_state)
from fauxlore.military_unit_catalog$s$);
end $migration$;

-- Apply current state conditions when construction is purchased; historical
-- project prices remain the amounts actually paid at the start of the build.
do $migration$
declare fn text; marker text;
begin
  fn:=pg_get_functiondef('fauxlore.military_start_port_construction(integer,jsonb)'::regprocedure);
  marker:=$s$balance_value numeric; project_key bigint;$s$;
  if position(marker in fn)=0 then raise exception 'Port declaration changed'; end if;
  fn:=replace(fn,marker,$s$balance_value numeric; cost_value numeric; project_key bigint;$s$);
  marker:=$s$  if coalesce(balance_value,0)<10000 then raise sqlstate '22023' using message='Для порта нужно 10 000 G'; end if;$s$;
  if position(marker in fn)=0 then raise exception 'Port cost check changed'; end if;
  fn:=replace(fn,marker,$s$  cost_value:=floor(10000*fauxlore.state_cost_multiplier(sid));
  if coalesce(balance_value,0)<cost_value then raise sqlstate '22023' using message=format('Для порта нужно %s G',cost_value); end if;$s$);
  fn:=replace(fn,$s$values(sid,province_key,x_value,y_value,10000,1,year_value,turn_value)$s$,$s$values(sid,province_key,x_value,y_value,cost_value,1,year_value,turn_value)$s$);
  fn:=replace(fn,$s$balance=balance-10000$s$,$s$balance=balance-cost_value$s$);
  fn:=replace(fn,$s$treasury=treasury-10000$s$,$s$treasury=treasury-cost_value$s$);
  fn:=replace(fn,$s$'cost',10000,'turns',1$s$,$s$'cost',cost_value,'turns',1$s$);
  if position($s$balance=balance-10000$s$ in fn)>0 or position($s$'cost',10000,'turns',1$s$ in fn)>0 then raise exception 'Port price replacement failed'; end if;
  execute fn;

  fn:=pg_get_functiondef('public.garrison_api(text,integer,integer,jsonb)'::regprocedure);
  marker:=$s$cost_value:=floor(quantity_value*unit_row.hire_cost*.7*greatest(0,1+fauxlore.state_permanent_modifier_total(sid,array['garrison_hire_cost'],province_key,null)));$s$;
  if position(marker in fn)=0 then raise exception 'Garrison hire changed'; end if;
  fn:=replace(fn,marker,$s$cost_value:=floor(quantity_value*unit_row.hire_cost*.7*greatest(0,1+fauxlore.state_permanent_modifier_total(sid,array['garrison_hire_cost'],province_key,null))*fauxlore.state_cost_multiplier(sid));$s$);
  marker:=$s$else (array[0,50000,150000,300000])[current_level+1] end);$s$;
  if position(marker in fn)=0 then raise exception 'Fort construction cost changed'; end if;
  fn:=replace(fn,marker,marker||$s$
  cost_value:=floor(cost_value*fauxlore.state_cost_multiplier(sid));$s$);
  execute fn;
end $migration$;

-- Apply the multiplier to mercenaries and paid spearmen in both the quote
-- and settlement paths. Free starter troops stay free.
do $migration$
declare fn text; before_text text; after_text text;
begin
  fn:=pg_get_functiondef('fauxlore.military_actions_extra(text,integer,jsonb)'::regprocedure);
  before_text:=$s$price:=floor(group_row.price*greatest(0,1+fauxlore.state_permanent_modifier_total(sid,array['mercenary_hire_cost'],null,null)));$s$;
  after_text:=$s$price:=floor(group_row.price*greatest(0,1+fauxlore.state_permanent_modifier_total(sid,array['mercenary_hire_cost'],null,null))*fauxlore.state_cost_multiplier(sid));$s$;
  if position(before_text in fn)=0 then raise exception 'Mercenary hire changed'; end if;
  fn:=replace(fn,before_text,after_text);
  before_text:=$s$price:=2500*greatest(1,existing_count-limit_value+2);$s$;
  if position(before_text in fn)=0 then raise exception 'Leader hire changed'; end if;
  fn:=replace(fn,before_text,$s$price:=floor(2500*greatest(1,existing_count-limit_value+2)*fauxlore.state_cost_multiplier(sid));$s$);
  execute fn;

  fn:=pg_get_functiondef('fauxlore.charge_army_upkeep_before_turn()'::regprocedure);
  before_text:=$s$greatest(0,fu.quantity-f.free_upkeep_quantity)*u.upkeep$s$;
  if position(before_text in fn)=0 then raise exception 'Spearman upkeep changed'; end if;
  fn:=replace(fn,before_text,before_text||$s$*fauxlore.military_unit_cost_factor(f.state_id,u.id,'upkeep')$s$);
  before_text:=$s$formation_row.mercenary_price*greatest(0,1+fauxlore.state_permanent_modifier_total(state_row.state_id,array['mercenary_upkeep'],null,null))$s$;
  if position(before_text in fn)=0 then raise exception 'Mercenary upkeep settlement changed'; end if;
  execute replace(fn,before_text,before_text||$s$*fauxlore.state_cost_multiplier(state_row.state_id)$s$);

  fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
  before_text:=$s$floor(g.price*greatest(0,1+fauxlore.state_permanent_modifier_total(sid,array['mercenary_hire_cost'],null,null)))$s$;
  after_text:=$s$floor(g.price*greatest(0,1+fauxlore.state_permanent_modifier_total(sid,array['mercenary_hire_cost'],null,null))*fauxlore.state_cost_multiplier(sid))$s$;
  if position(before_text in fn)=0 then raise exception 'Mercenary hire quote changed'; end if;
  fn:=replace(fn,before_text,after_text);
  before_text:=$s$g.price*greatest(0,1+fauxlore.state_permanent_modifier_total(sid,array['mercenary_upkeep'],null,null))$s$;
  if position(before_text in fn)=0 then raise exception 'Mercenary upkeep quote changed'; end if;
  execute replace(fn,before_text,before_text||$s$*fauxlore.state_cost_multiplier(sid)$s$);

  fn:=pg_get_functiondef('fauxlore.military_upkeep_summary(integer)'::regprocedure);
  before_text:=$s$array['mercenary_upkeep'],null,null))),0) into mercenary_cost$s$;
  after_text:=$s$array['mercenary_upkeep'],null,null))*fauxlore.state_cost_multiplier(target_state)),0) into mercenary_cost$s$;
  if position(before_text in fn)=0 then raise exception 'Mercenary summary changed'; end if;
  execute replace(fn,before_text,after_text);
end $migration$;

create or replace function fauxlore.port_upkeep(target_state integer)
returns numeric language sql stable security definer set search_path='' as $function$
  select count(*)*floor(200*fauxlore.state_cost_multiplier(target_state))
  from fauxlore.map_markers m
  left join fauxlore.military_port_builds b on b.marker_id=m.id
  where m.type='port' and coalesce(m.state_id,b.state_id)=target_state
$function$;
revoke all on function fauxlore.port_upkeep(integer) from public,anon,authenticated;

alter table fauxlore.state_budget_ledger drop constraint state_budget_ledger_kind_check;
alter table fauxlore.state_budget_ledger add constraint state_budget_ledger_kind_check
  check (kind in ('army_upkeep','debt_repayment','estate_loyalty_investment','estate_military_tax','port_upkeep'));

create or replace function fauxlore.charge_port_upkeep_before_turn()
returns trigger language plpgsql security definer set search_path='' as $function$
declare row_value record; expense numeric; closing_balance numeric;
begin
  if (new.year,new.turn)=(old.year,old.turn) then return new; end if;
  for row_value in select state_id from fauxlore.state_profiles order by state_id loop
    expense:=fauxlore.port_upkeep(row_value.state_id);
    if coalesce(expense,0)<=0 then continue; end if;
    update fauxlore.state_treasuries set balance=balance-expense,updated_at=now()
      where state_id=row_value.state_id and estate='Корона';
    if not found then raise exception 'Missing crown treasury for port upkeep'; end if;
    insert into fauxlore.state_budget_ledger(state_id,estate,year,turn,kind,cash_delta,debt_delta,details)
      values(row_value.state_id,'Корона',old.year,old.turn,'port_upkeep',-expense,0,'{}'::jsonb);
    select coalesce(sum(balance),0) into closing_balance from fauxlore.state_treasuries where state_id=row_value.state_id;
    update fauxlore.state_profiles set treasury=closing_balance where state_id=row_value.state_id;
    update fauxlore.turn_economy_reports set report=(select coalesce(jsonb_agg(
      case when (e.value->>'id')::integer=row_value.state_id then e.value||jsonb_build_object(
        'port_upkeep',expense,'closing_treasury',closing_balance,'tax_buckets',
        (select jsonb_object_agg(estate,balance) from fauxlore.state_treasuries where state_id=row_value.state_id))
      else e.value end order by e.ord),'[]'::jsonb) from jsonb_array_elements(report) with ordinality e(value,ord))
      where year=old.year and turn=old.turn;
  end loop;
  return new;
end $function$;
revoke all on function fauxlore.charge_port_upkeep_before_turn() from public,anon,authenticated;
create trigger game_calendar_port_upkeep before update of year,turn on fauxlore.game_calendar
  for each row execute function fauxlore.charge_port_upkeep_before_turn();

-- Price quotes use the same validation and formula as the actual action.
do $migration$
declare fn text; marker text; old_part text;
begin
  fn:=pg_get_functiondef('public.garrison_api(text,integer,integer,jsonb)'::regprocedure);
  marker:=$s$if action not in ('hire','build') then$s$;
  if position(marker in fn)=0 then raise exception 'Garrison action validation changed'; end if;
  fn:=replace(fn,marker,$s$if action not in ('hire','build','quote_hire','quote_build') then$s$);
  marker:=$s$ select * into province_row from fauxlore.provinces where id=province_key and kind='land' for update;$s$;
  if position(marker in fn)=0 then raise exception 'Garrison province lookup changed'; end if;
  fn:=replace(fn,marker,$s$ if action in ('quote_hire','quote_build') then
  select * into province_row from fauxlore.provinces where id=province_key and kind='land';
 else
  select * into province_row from fauxlore.provinces where id=province_key and kind='land' for update;
 end if;$s$);
  marker:=$s$ select * into site from fauxlore.garrison_sites where province_id=province_key for update;$s$;
  if position(marker in fn)=0 then raise exception 'Garrison site lookup changed'; end if;
  fn:=replace(fn,marker,$s$ if action in ('quote_hire','quote_build') then
  select * into site from fauxlore.garrison_sites where province_id=province_key;
 else
  select * into site from fauxlore.garrison_sites where province_id=province_key for update;
 end if;$s$);
  marker:=$s$if action='hire' then$s$;
  if position(marker in fn)=0 then raise exception 'Garrison hire action changed'; end if;
  fn:=replace(fn,marker,$s$if action in ('hire','quote_hire') then$s$);
  marker:=$s$  perform 1 from fauxlore.state_profiles where state_id=sid and recruits>=quantity_value*unit_row.recruit_cost for update;$s$;
  if position(marker in fn)=0 then raise exception 'Garrison recruit validation changed'; end if;
  fn:=replace(fn,marker,$s$  if action='quote_hire' then
    perform 1 from fauxlore.state_profiles where state_id=sid and recruits>=quantity_value*unit_row.recruit_cost;
  else
    perform 1 from fauxlore.state_profiles where state_id=sid and recruits>=quantity_value*unit_row.recruit_cost for update;
  end if;$s$);
  marker:=$s$  select balance into balance_value from fauxlore.state_treasuries where state_id=sid and estate=coalesce(site.sponsor_estate,'Корона') for update;$s$;
  if position(marker in fn)=0 then raise exception 'Garrison quote position changed'; end if;
  -- This line occurs after the hire price and again after the build price.
  fn:=replace(fn,marker,$s$  if action in ('quote_hire','quote_build') then return jsonb_build_object('cost',cost_value); end if;
$s$||marker);
  marker:=$s$'development',p.development,'neutral',v.category_id is null,'owned',v.category_id=sid,$s$;
  if position(marker in fn)=0 then raise exception 'Garrison snapshot changed'; end if;
  fn:=replace(fn,marker,marker||$s$'troop_upkeep',coalesce(fauxlore.garrison_troop_upkeep(p.id),0),
     'fortification_upkeep',coalesce(fauxlore.garrison_site_upkeep(p.id),0)-coalesce(fauxlore.garrison_troop_upkeep(p.id),0),$s$);
  marker:=$s$'name',c.name,'quantity',u.quantity,'recruits',c.recruit_cost,'upkeep',c.upkeep)$s$;
  if position(marker in fn)=0 then raise exception 'Garrison unit upkeep snapshot changed'; end if;
  fn:=replace(fn,marker,$s$'name',c.name,'quantity',u.quantity,'recruits',c.recruit_cost,'upkeep',c.upkeep,
    'total_upkeep',u.quantity*c.upkeep*.4*greatest(0,1+fauxlore.state_permanent_modifier_total(sid,array['garrison_upkeep'],p.id,null))*fauxlore.state_cost_multiplier(sid))$s$);
  old_part:=$s$(select coalesce(sum(round(u.quantity*c.upkeep*.4,2)),0)
     from fauxlore.garrison_units u join fauxlore.garrison_sites g on g.province_id=u.province_id
     join fauxlore.military_unit_catalog c on c.id=u.unit_id where g.state_id=sid)$s$;
  if position(old_part in fn)=0 then raise exception 'Garrison snapshot totals changed'; end if;
  fn:=replace(fn,old_part,$s$(select coalesce(sum(fauxlore.garrison_troop_upkeep(g.province_id)),0) from fauxlore.garrison_sites g where g.state_id=sid)$s$);
  execute fn;

  fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
  marker:=$s$'state_id',sid,'is_admin',is_admin,$s$;
  if position(marker in fn)=0 then raise exception 'Military snapshot changed'; end if;
  fn:=replace(fn,marker,marker||$s$'port_build_cost',floor(10000*fauxlore.state_cost_multiplier(sid)),'port_upkeep_per_turn',floor(200*fauxlore.state_cost_multiplier(sid)),$s$);
  marker:=$s$'upkeep_breakdown',fauxlore.military_upkeep_summary(sid),$s$;
  if position(marker in fn)=0 then raise exception 'Military upkeep snapshot changed'; end if;
  fn:=replace(fn,marker,marker||$s$'leader_hire_cost',floor(2500*greatest(1,
    (select count(*) from fauxlore.military_leaders where state_id=sid and status in ('active','wounded','captured'))
    -greatest(1,2+floor(coalesce((indicator_snapshot->>'population')::numeric,0)/1000000)::integer+
      case when coalesce((indicator_snapshot->>'stability')::numeric,.5)<.3 then -1
      when coalesce((indicator_snapshot->>'stability')::numeric,.5)>=.7 then 1 else 0 end)+2)*fauxlore.state_cost_multiplier(sid)),$s$);
  marker:=$s$when f.kind='militia' then fu.quantity*u.upkeep$s$;
  if position(marker in fn)=0 then raise exception 'Militia unit snapshot changed'; end if;
  fn:=replace(fn,marker,$s$when f.kind='militia' then floor(fu.quantity*u.upkeep*fauxlore.state_cost_multiplier(sid))$s$);
  execute fn;
end $migration$;

do $migration$
declare fn text; marker text;
begin
  fn:=pg_get_functiondef('fauxlore.military_upkeep_summary(integer)'::regprocedure);
  marker:=$s$'mercenaries',mercenary_cost,'garrisons',garrison_cost,$s$;
  if position(marker in fn)=0 then raise exception 'Military upkeep summary changed'; end if;
  fn:=replace(fn,marker,marker||$s$'ports',fauxlore.port_upkeep(target_state),$s$);
  marker:=$s$'total',army_cost+fleet_cost+militia_cost+mercenary_cost+garrison_cost$s$;
  if position(marker in fn)=0 then raise exception 'Military upkeep total changed'; end if;
  execute replace(fn,marker,marker||$s$+fauxlore.port_upkeep(target_state)$s$);
end $migration$;
