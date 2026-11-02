-- Modifiers tied to both the colonizing state and the target province.
create table fauxlore.colonization_dice_assignments (
  id bigint generated always as identity primary key,
  state_id integer not null,
  province_id integer not null references fauxlore.provinces(id) on delete cascade,
  value integer not null check (value between -1000 and 1000 and value <> 0),
  source text not null check (length(source) between 1 and 120),
  created_by bigint not null references fauxlore.accounts(id),
  created_at timestamptz not null default now()
);
create index on fauxlore.colonization_dice_assignments(state_id,province_id);
alter table fauxlore.colonization_dice_assignments enable row level security;
revoke all on fauxlore.colonization_dice_assignments from public,anon,authenticated;

create function fauxlore.admin_colonization_modifiers_api(action text,payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor fauxlore.accounts; sid integer; pid integer; amount integer; label text; new_id bigint;
begin
  actor:=fauxlore.current_account();
  if coalesce(actor.role,'')<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if action='snapshot' then
    return jsonb_build_object(
      'states',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name) order by name) from fauxlore.map_categories where layer='states'),'[]'::jsonb),
      'provinces',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name) order by name,id) from fauxlore.provinces where kind='land'),'[]'::jsonb),
      'assigned',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'state',s.name,'province',p.name,'value',a.value,'source',a.source) order by a.id desc)
        from fauxlore.colonization_dice_assignments a join fauxlore.map_categories s on s.layer='states' and s.id=a.state_id join fauxlore.provinces p on p.id=a.province_id),'[]'::jsonb));
  elsif action='assign' then
    sid:=(payload->>'state_id')::integer; pid:=(payload->>'province_id')::integer;
    amount:=(payload->>'value')::integer; label:=btrim(coalesce(payload->>'source',''));
    if not exists(select 1 from fauxlore.map_categories where layer='states' and id=sid)
      or not exists(select 1 from fauxlore.provinces where id=pid and kind='land')
      or amount is null or amount=0 or abs(amount)>1000 or length(label) not between 1 and 120 then
      raise sqlstate '22023' using message='Проверьте государство, провинцию, значение и источник'; end if;
    insert into fauxlore.colonization_dice_assignments(state_id,province_id,value,source,created_by)
      values(sid,pid,amount,label,actor.id) returning id into new_id;
    return jsonb_build_object('id',new_id);
  elsif action='delete' then
    delete from fauxlore.colonization_dice_assignments where id=(payload->>'id')::bigint;
    if not found then raise sqlstate 'P0002' using message='Модификатор не найден'; end if;
    return jsonb_build_object('deleted',true);
  end if;
  raise sqlstate '22023' using message='Неизвестное действие';
end $$;
revoke all on function fauxlore.admin_colonization_modifiers_api(text,jsonb) from public,anon,authenticated;
grant execute on function fauxlore.admin_colonization_modifiers_api(text,jsonb) to authenticated;
create function public.admin_colonization_modifiers_api(action text,payload jsonb default '{}'::jsonb)
returns jsonb language sql security invoker set search_path='' as $$ select fauxlore.admin_colonization_modifiers_api(action,payload) $$;
revoke all on function public.admin_colonization_modifiers_api(text,jsonb) from public,anon;
grant execute on function public.admin_colonization_modifiers_api(text,jsonb) to authenticated;

-- Returns the same complete list to the preview, the roll and its notification.
create function fauxlore.colonization_dice_modifiers(sid integer,pid integer,gold_bonus integer,recruit_bonus integer,path_penalty integer)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb:='[]'::jsonb; terrain text; race_id integer; religion_id integer; official_race integer; official_religion integer;
  item jsonb; total numeric:=0; previous integer:=0; current_value integer; adjustment integer; a record;
begin
  select p.terrain_type,sp.official_race_id,sp.official_religion_id,
    (select category_id from fauxlore.province_values where province_id=pid and layer='races'),
    (select category_id from fauxlore.province_values where province_id=pid and layer='religions')
    into terrain,official_race,official_religion,race_id,religion_id
    from fauxlore.provinces p join fauxlore.state_profiles sp on sp.state_id=sid where p.id=pid;
  if gold_bonus<>0 then result:=result||jsonb_build_array(jsonb_build_object('source','Вложенное золото','value',gold_bonus)); end if;
  if recruit_bonus<>0 then result:=result||jsonb_build_array(jsonb_build_object('source','Дополнительные рекруты','value',recruit_bonus)); end if;
  if path_penalty<>0 then result:=result||jsonb_build_array(jsonb_build_object('source','Морской маршрут','value',-path_penalty)); end if;
  if exists(select 1 from fauxlore.garrison_sites where province_id=pid and state_id=sid and fort_level>0) then
    result:=result||jsonb_build_array(jsonb_build_object('source','Свой форт','value',10)); end if;
  adjustment:=case terrain when 'high_mountains' then -15 when 'mountains' then -10 when 'forest' then -5 when 'marsh' then -15 else 0 end;
  if adjustment<>0 then result:=result||jsonb_build_array(jsonb_build_object('source',case terrain when 'high_mountains' then 'Высокие горы' when 'mountains' then 'Горы' when 'forest' then 'Леса' else 'Болота' end,'value',adjustment)); end if;
  if race_id is not null and official_race is not null and race_id<>official_race then result:=result||jsonb_build_array(jsonb_build_object('source','Несовпадение расы','value',-5)); end if;
  if religion_id is not null and official_religion is not null and religion_id<>official_religion then result:=result||jsonb_build_array(jsonb_build_object('source','Несовпадение религии','value',-5)); end if;
  for a in select source,value from fauxlore.colonization_dice_assignments where state_id=sid and province_id=pid order by id loop
    result:=result||jsonb_build_array(jsonb_build_object('source',a.source,'value',a.value));
  end loop;
  -- Apply the same global eligibility as state_permanent_modifier_total(..., null, null).
  for item in select value from jsonb_array_elements(fauxlore.state_permanent_modifiers(sid)) value
    where value->>'key'='colonization_chance' and value->>'target_trade_zone_id' is null
      and (value->>'source_kind'<>'admin' or value->>'target_province_id' is null)
      and coalesce(value->>'condition','')<>'Максимум'
      and not (value->>'source_kind' in ('race','religion') and value->>'scope'<>'Государство')
      and value->>'scope' not like 'Провинции %' and value->>'scope' not like '% + %'
      and value->>'scope' not in ('Регионы','Городские и Столичная')
      and (coalesce(value->>'condition','')<>'Лояльность Знати выше 60%' or coalesce((select effective_loyalty from fauxlore.effective_estate_loyalties(sid) where name='Знать'),0)>.60)
      and (coalesce(value->>'condition','')<>'Лояльность ключевых сословий выше 60%' or (exists(select 1 from fauxlore.effective_estate_loyalties(sid) where status='Ключевое') and not exists(select 1 from fauxlore.effective_estate_loyalties(sid) where status='Ключевое' and effective_loyalty<=.60)))
  loop
    total:=total+coalesce((item->>'value')::numeric,0); current_value:=floor(total*100)::integer;
    if current_value<>previous then result:=result||jsonb_build_array(jsonb_build_object('source',item->>'source','value',current_value-previous)); end if;
    previous:=current_value;
  end loop;
  if previous<>floor(fauxlore.state_permanent_modifier_total(sid,array['colonization_chance'],null,null)*100)::integer then
    raise exception 'Colonization modifier breakdown differs from total'; end if;
  return result;
end $$;
revoke all on function fauxlore.colonization_dice_modifiers(integer,integer,integer,integer,integer) from public,anon,authenticated;

do $migration$
declare fn text; marker text;
begin
  fn:=pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure);
  marker:='mission_key bigint; crown_balance numeric; p fauxlore.provinces; result_value jsonb; owner_id integer;';
  if position(marker in fn)=0 then raise exception 'Colonization declarations changed'; end if;
  fn:=replace(fn,marker,marker||' dice_modifiers jsonb; dice_total integer; dice_detail text;');
  marker:='if action=''preview'' then';
  if position(marker in fn)=0 then raise exception 'Colonization preview changed'; end if;
  fn:=replace(fn,marker,$s$gold_bonus:=least(15,greatest(0,((gold_value-gold_base)/1000)*5));
    recruit_bonus:=least(15,greatest(0,((recruits_value-50)/100)*5));
    dice_modifiers:=fauxlore.colonization_dice_modifiers(state_key,target_key,gold_bonus,recruit_bonus,path_penalty);
    select coalesce(sum((value->>'value')::integer),0),coalesce(string_agg(format('%s %s (%s)',case when (value->>'value')::integer>0 then '+' else '−' end,abs((value->>'value')::integer),value->>'source'),' ' order by case when (value->>'value')::integer>0 then 0 else 1 end,ord),'')
      into dice_total,dice_detail from jsonb_array_elements(dice_modifiers) with ordinality as t(value,ord);
    if action='preview' then$s$);
  marker:='''recruit_bonus'',recruit_bonus,''route_penalty'',path_penalty,';
  if position(marker in fn)=0 then raise exception 'Colonization response changed'; end if;
  fn:=replace(fn,marker,marker||'''modifiers'',dice_modifiers,');
  marker:='roll_value+gold_bonus+recruit_bonus-path_penalty+floor(fauxlore.state_permanent_modifier_total(state_key,array[''colonization_chance''],null,null)*100)::integer+case when exists(select 1 from fauxlore.garrison_sites g where g.province_id=target_key and g.state_id=state_key and g.fort_level>0) then 10 else 0 end';
  if position(marker in fn)=0 then raise exception 'Colonization formula changed'; end if;
  fn:=replace(fn,marker,'roll_value+dice_total');
  marker:='Итог броска: %s. Потери:';
  if position(marker in fn)=0 then raise exception 'Colonization notification changed'; end if;
  fn:=replace(fn,marker,'Бросок: %s. Потери:');
  marker:=E'      final_value,\n      recruits_value-survivors,';
  if position(marker in fn)=0 then raise exception 'Colonization notification arguments changed'; end if;
  fn:=replace(fn,marker,E'      format(''%s %s = %s%s'',roll_value,dice_detail,final_value,case when roll_value+dice_total<>final_value then '' (с учётом границ 0–100)'' else '''' end),\n      recruits_value-survivors,');
  execute fn;
end $migration$;
notify pgrst,'reload schema';
