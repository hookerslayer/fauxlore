-- The principle matrix has three estate statuses. Retire the unused fourth
-- status without changing any existing key estate's rates or loyalty.
update fauxlore.state_group_politics
set status='Ключевое'
where group_type='estate' and status='Господствующее';

alter table fauxlore.state_group_politics
  add constraint state_group_politics_estate_status_check
  check (group_type<>'estate' or status in ('Ключевое','Значимое','Бесправное'));

update fauxlore.economy_parameters
set config=jsonb_set(config,'{estateTaxGreed}',
      (config->'estateTaxGreed')-
      array['Господствующее|Корона','Господствующее|Знать',
            'Господствующее|Духовенство','Господствующее|Горожане',
            'Господствующее|Крестьяне']),
    updated_at=now()
where singleton=true;

create or replace function fauxlore.split_province_tax(gross numeric,belonging text,status text,cfg jsonb)
returns table(crown numeric,estate numeric) language plpgsql immutable set search_path='' as $$
declare greed numeric;
begin
  if gross is null or gross<0 then raise sqlstate '22023' using message='Сумма налога не может быть отрицательной'; end if;
  if belonging is null or belonging='Отсутствует' then return query select round(gross,2),0::numeric; return; end if;
  if belonging not in ('Корона','Знать','Духовенство','Горожане','Крестьяне') or status not in ('Ключевое','Значимое','Бесправное') then
    raise sqlstate '22023' using message='Неизвестное сословие или его статус';
  end if;
  greed:=nullif(cfg#>>array['estateTaxGreed',status||'|'||belonging],'')::numeric;
  if greed is null or greed<0 or greed>1 then raise sqlstate '22023' using message='Не задан корректный коэффициент распределения налога'; end if;
  return query select round(gross*(1-greed),2),gross-round(gross*(1-greed),2);
end $$;

-- Patch the current helper definition so later urbanization and corruption
-- changes to the same function remain intact.
do $$
declare fn text; old_part text; new_part text;
begin
  fn:=pg_get_functiondef('fauxlore.state_indicators_before_urbanization(integer)'::regprocedure);
  old_part:='case status when ''Господствующее'' then 1 when ''Ключевое'' then 1.5';
  new_part:='case status when ''Ключевое'' then 1.5';
  if position(old_part in fn)=0 then raise exception 'Estate stability status branch not found'; end if;
  execute replace(fn,old_part,new_part);

  fn:=pg_get_functiondef('fauxlore.allocate_new_state_belonging()'::regprocedure);
  old_part:='when ''Господствующее'' then 4 when ''Ключевое'' then 3';
  new_part:='when ''Ключевое'' then 3';
  if position(old_part in fn)=0 then raise exception 'Initial estate allocation branch not found'; end if;
  execute replace(fn,old_part,new_part);
end $$;
