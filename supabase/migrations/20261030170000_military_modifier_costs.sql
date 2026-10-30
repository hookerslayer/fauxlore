-- Resolve the same unit cost factors for settlement and the military UI.
create or replace function fauxlore.military_unit_cost_factor(target_state integer,target_unit bigint,cost_kind text)
returns numeric language sql stable security definer set search_path='' as $function$
select greatest(0,1+fauxlore.state_permanent_modifier_total(target_state,
  case cost_kind
    when 'hire' then array_remove(array[
      case when u.domain='naval' then 'fleet_hire_cost' end,
      case when u.domain='naval' then 'ship_hire_cost' end,
      case when u.category='Кавалерия' then 'cavalry_hire_cost' end,
      case when u.name='Лучник' then 'archer_hire_cost' end,
      case when u.name='Арбалетчик' then 'crossbow_hire_cost' end,
      case when u.name='Пищальник' or u.domain='siege' then 'firearms_hire_cost' end,
      case when u.name in ('Лучник','Арбалетчик','Пищальник') or u.domain='siege' then 'ranged_hire_cost' end,
      case when u.domain in ('land','siege') then 'regular_hire_cost' end
    ]::text[],null)
    when 'upkeep' then array_remove(array[
      case when u.domain='naval' then 'fleet_upkeep' end,
      case when u.domain='naval' then 'ship_upkeep' end,
      case when u.category='Кавалерия' then 'cavalry_upkeep' end,
      case when u.name='Лучник' then 'archer_upkeep' end,
      case when u.name='Арбалетчик' then 'crossbow_upkeep' end,
      case when u.name='Пищальник' or u.domain='siege' then 'firearms_upkeep' end,
      case when u.name in ('Лучник','Арбалетчик','Пищальник') or u.domain='siege' then 'ranged_upkeep' end,
      case when u.domain in ('land','siege') then 'regular_upkeep' end
    ]::text[],null)
    else array[]::text[] end,null,null))
from fauxlore.military_unit_catalog u where u.id=target_unit
$function$;
revoke all on function fauxlore.military_unit_cost_factor(integer,bigint,text) from public,anon,authenticated;

do $migration$
declare fn text; old_fragment text; new_fragment text; start_pos integer;
begin
  fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
  old_fragment:='price:=floor(amount*unit_row.hire_cost*greatest(0,1+fauxlore.state_permanent_modifier_total(sid,';
  start_pos:=position(old_fragment in fn);
  if start_pos=0 then raise exception 'Regular hire formula changed'; end if;
  old_fragment:=split_part(substr(fn,start_pos),';',1)||';';
  fn:=replace(fn,old_fragment,'price:=floor(amount*unit_row.hire_cost*fauxlore.military_unit_cost_factor(sid,unit_row.id,''hire''));');
  if position('military_unit_cost_factor(sid,unit_row.id' in fn)=0 then raise exception 'Regular hire replacement failed'; end if;
  old_fragment:='jsonb_agg(to_jsonb(u) order by u.domain,u.id)';
  new_fragment:='jsonb_agg(to_jsonb(u)||jsonb_build_object(''hire_factor'',fauxlore.military_unit_cost_factor(sid,u.id,''hire''),''upkeep_factor'',fauxlore.military_unit_cost_factor(sid,u.id,''upkeep'')) order by u.domain,u.id)';
  if position(old_fragment in fn)=0 then raise exception 'Military catalog snapshot changed'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:='to_jsonb(g)||jsonb_build_object(''hired_by'',';
  new_fragment:='to_jsonb(g)||jsonb_build_object(''hire_price'',floor(g.price*greatest(0,1+fauxlore.state_permanent_modifier_total(sid,array[''mercenary_hire_cost''],null,null))),''upkeep_price'',g.price*greatest(0,1+fauxlore.state_permanent_modifier_total(sid,array[''mercenary_upkeep''],null,null)),''hired_by'',';
  if position(old_fragment in fn)=0 then raise exception 'Mercenary snapshot changed'; end if;
  execute replace(fn,old_fragment,new_fragment);

  fn:=pg_get_functiondef('fauxlore.charge_army_upkeep_before_turn()'::regprocedure);
  old_fragment:='fu.quantity*u.upkeep*greatest(0,1+fauxlore.state_permanent_modifier_total(f.state_id,';
  start_pos:=position(old_fragment in fn);
  if start_pos=0 then raise exception 'Regular upkeep formula changed'; end if;
  old_fragment:=split_part(substr(fn,start_pos),' end),0)',1);
  if length(old_fragment)>1000 or length(old_fragment)<100 then raise exception 'Regular upkeep expression changed'; end if;
  fn:=replace(fn,old_fragment,'fu.quantity*u.upkeep*fauxlore.military_unit_cost_factor(f.state_id,u.id,''upkeep'')');
  if position('military_unit_cost_factor(f.state_id,u.id' in fn)=0 then raise exception 'Regular upkeep replacement failed'; end if;
  execute fn;

  fn:=pg_get_functiondef('fauxlore.military_actions_extra(text,integer,jsonb)'::regprocedure);
  old_fragment:='select balance into balance_value from fauxlore.state_treasuries where state_id=sid and estate=''Корона'' for update;'||chr(10)||
    '  if coalesce(balance_value,0)<group_row.price';
  new_fragment:='price:=floor(group_row.price*greatest(0,1+fauxlore.state_permanent_modifier_total(sid,array[''mercenary_hire_cost''],null,null)));'||chr(10)||
    '  select balance into balance_value from fauxlore.state_treasuries where state_id=sid and estate=''Корона'' for update;'||chr(10)||
    '  if coalesce(balance_value,0)<price';
  if position(old_fragment in fn)=0 then raise exception 'Mercenary hire balance formula changed'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  fn:=replace(fn,'set balance=balance-group_row.price,updated_at=now() where state_id=sid and estate=''Корона'';','set balance=balance-price,updated_at=now() where state_id=sid and estate=''Корона'';');
  fn:=replace(fn,'set treasury=treasury-group_row.price where state_id=sid;','set treasury=treasury-price where state_id=sid;');
  fn:=replace(fn,'''formation_id'',formation_key,''cost'',group_row.price);','''formation_id'',formation_key,''cost'',price);');
  execute fn;
end
$migration$;
notify pgrst,'reload schema';
