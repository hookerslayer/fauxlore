-- Read the province's modifiers even before a mission passes its resource and route checks.
do $migration$
declare fn text; marker text;
begin
  fn:=pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure);
  marker:='if action=''snapshot'' then';
  if position(marker in fn)=0 then raise exception 'Colonization snapshot marker changed'; end if;
  fn:=replace(fn,marker,$s$if action='modifiers' then
    target_key:=(payload->>'province_id')::integer;
    if not exists(select 1 from fauxlore.provinces where id=target_key and kind='land') then
      raise sqlstate '22023' using message='Выберите сухопутную провинцию'; end if;
    if not fauxlore.neutral_fort_colonizable(state_key,target_key) then
      raise sqlstate '22023' using message='Провинция недоступна для колонизации'; end if;
    sea_value:=coalesce((payload->>'sea')::boolean,false);
    gold_base:=case when sea_value then 2400 else 1200 end;
    gold_value:=coalesce((payload->>'gold')::integer,gold_base);
    recruits_value:=coalesce((payload->>'recruits')::integer,50);
    if gold_value<0 or gold_value>10000000 or recruits_value<0 or recruits_value>1000000 then
      raise sqlstate '22023' using message='Проверьте сумму и число рекрутов'; end if;
    gold_bonus:=least(15,greatest(0,((gold_value-gold_base)/1000)*5));
    recruit_bonus:=least(15,greatest(0,((recruits_value-50)/100)*5));
    return jsonb_build_object('modifiers',fauxlore.colonization_dice_modifiers(state_key,target_key,gold_bonus,recruit_bonus,0));
  end if;
  if action='snapshot' then$s$);
  execute fn;
end $migration$;
