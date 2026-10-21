-- Store province control as an integer percentage (0..100), defaulting to full control.
-- Legacy text values that are not valid percentages are safely normalized to 100.
alter table fauxlore.provinces
  alter column control type smallint using (
    case
      when btrim(coalesce(control, '')) ~ '^[0-9]{1,3}%?$'
       and replace(btrim(control), '%', '')::integer between 0 and 100
      then replace(btrim(control), '%', '')::smallint
      else 100::smallint
    end
  );
update fauxlore.provinces set control=100 where control is null;
alter table fauxlore.provinces alter column control set default 100;
alter table fauxlore.provinces alter column control set not null;
alter table fauxlore.provinces add constraint provinces_control_range check (control between 0 and 100);

create or replace function fauxlore.normalize(field text, value jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare t text:=nullif(btrim(value#>>'{}'),''); limit_length integer;
begin
  if field is null then raise sqlstate '22023' using message='Неизвестный параметр'; end if;
  if field in ('capital','city') then
    if jsonb_typeof(value) is distinct from 'boolean' then raise sqlstate '22023' using message='Укажите да или нет'; end if;
    return value;
  elsif field in ('population','development','control') then
    if value='null' and field='development' then return value; end if;
    if jsonb_typeof(value) is distinct from 'number' or t!~'^[0-9]+$' then
      raise sqlstate '22023' using message=case when field='control' then 'Контроль должен быть целым числом от 0 до 100' else 'Укажите целое неотрицательное число' end; end if;
    if t::numeric>(case when field='population' then 2000000000 when field='control' then 100 else 1000000 end) or
      (field='control' and t::numeric<0) then
      raise sqlstate '22023' using message=case when field='control' then 'Контроль должен быть целым числом от 0 до 100' else 'Укажите целое неотрицательное число' end; end if;
    return value;
  elsif field='belonging' then
    if t is null or t not in ('Корона','Знать','Духовенство','Горожане','Крестьяне','Отсутствует') then raise sqlstate '22023' using message='Неизвестная принадлежность'; end if;
  elsif field='trade_status' then
    if t is null or t not in ('Отсутствует','Устье реки','Природный порт','Центр торговли I','Центр торговли II','Центр торговли III') then raise sqlstate '22023' using message='Неизвестный торговый статус'; end if;
  elsif field='province_type' then
    if t is null or t not in ('Столица','Город','Регион','Территория','Нейтральная') then raise sqlstate '22023' using message='Неизвестный тип провинции'; end if;
  elsif field='terrain_type' then
    if value='null' then return value; end if;
    if t is null or t not in ('forest','marsh') then raise sqlstate '22023' using message='Неизвестный тип местности'; end if;
  elsif field='name' then
    if t is null then raise sqlstate '22023' using message='Укажите название'; end if;
  elsif fauxlore.layer_for(field) is null then
    raise sqlstate '22023' using message='Неизвестный параметр';
  end if;
  if value<>'null' and jsonb_typeof(value)<>'string' then raise sqlstate '22023' using message='Некорректное текстовое значение'; end if;
  limit_length:=case when field='name' then 120 when field='state' then 100 else 80 end;
  if length(t)>limit_length then raise sqlstate '22023' using message='Слишком длинное значение'; end if;
  return coalesce(to_jsonb(t),'null');
end $$;

create or replace function fauxlore.edit_province(province_id integer, changes jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare p fauxlore.provinces; item record; value jsonb; layer_name text; category_id integer; column_name text;
begin
  select * into p from fauxlore.provinces where id=province_id for update;
  if not found then raise sqlstate 'P0002' using message='Провинция не найдена'; end if;
  if p.kind<>'land' then raise sqlstate '22023' using message='Редактировать можно только сухопутные провинции'; end if;
  if jsonb_typeof(changes)<>'object' or changes='{}' then raise sqlstate '22023' using message='Нет изменений'; end if;
  for item in select * from jsonb_each(changes) order by key loop
    value:=fauxlore.normalize(item.key,item.value); layer_name:=fauxlore.layer_for(item.key);
    if layer_name is not null then
      category_id:=fauxlore.category(layer_name,value#>>'{}',layer_name='states');
      if category_id is null then
        delete from fauxlore.province_values v where v.province_id=p.id and v.layer=layer_name;
      else
        insert into fauxlore.province_values values(p.id,layer_name,category_id)
          on conflict on constraint province_values_pkey do update set category_id=excluded.category_id;
      end if;
    else
      column_name:=case item.key when 'capital' then 'has_capital_marker' when 'city' then 'has_city_marker' else item.key end;
      p:=jsonb_populate_record(p,jsonb_build_object(column_name,value));
    end if;
  end loop;
  if p.has_capital_marker then p.province_type:='Столица';
  elsif p.has_city_marker then p.province_type:='Город';
  elsif not changes?'province_type' and changes ?| array['capital','city','state'] then
    p.province_type:=case when exists(select 1 from fauxlore.province_values v where v.province_id=p.id and layer='states') then 'Регион' else 'Нейтральная' end;
  end if;
  update fauxlore.provinces set name=p.name,province_type=p.province_type,population=p.population,
    development=p.development,control=p.control,terrain_type=p.terrain_type,
    has_capital_marker=p.has_capital_marker,has_city_marker=p.has_city_marker where id=p.id;
  return fauxlore.province_payload(p);
end $$;
