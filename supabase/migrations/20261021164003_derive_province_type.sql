-- Derive province type from city/capital markers. A successful future
-- colonization action can set Территориальная directly in that transaction.
alter table fauxlore.provinces drop constraint provinces_province_type_check;
alter table fauxlore.provinces alter column province_type set default 'Регион';

update fauxlore.provinces set province_type=case province_type
  when 'Столица' then 'Столичная'
  when 'Город' then 'Городская'
  when 'Территория' then 'Территориальная'
  when 'Нейтральная' then 'Регион'
  else province_type end;

alter table fauxlore.provinces add constraint provinces_province_type_check
  check (province_type in ('Столичная','Городская','Регион','Территориальная'));

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
    if jsonb_typeof(value) is distinct from 'number' or t!~'^\d+$' then
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
    raise sqlstate '22023' using message='Тип провинции определяется автоматически';
  elsif field='terrain_type' then
    if value='null' then return value; end if;
    if t is null or t not in ('forest','marsh') then raise sqlstate '22023' using message='Неизвестный тип местности'; end if;
  elsif field='occupation' then
    if value='null' then return value; end if;
    if jsonb_typeof(value) is distinct from 'string' or t is null then raise sqlstate '22023' using message='Выберите государство-оккупанта или очистите поле'; end if;
  elsif field='name' then
    if t is null then raise sqlstate '22023' using message='Укажите название'; end if;
  elsif fauxlore.layer_for(field) is null then
    raise sqlstate '22023' using message='Неизвестный параметр';
  end if;
  if value<>'null' and jsonb_typeof(value)<>'string' then raise sqlstate '22023' using message='Некорректное текстовое значение'; end if;
  limit_length:=case when field='name' then 120 when field in ('state','occupation') then 100 else 80 end;
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
      if category_id is null then delete from fauxlore.province_values v where v.province_id=p.id and v.layer=layer_name;
      else insert into fauxlore.province_values values(p.id,layer_name,category_id)
        on conflict on constraint province_values_pkey do update set category_id=excluded.category_id; end if;
    else
      if item.key='occupation' and value<>'null' then perform fauxlore.category('states',value#>>'{}',false); end if;
      column_name:=case item.key when 'capital' then 'has_capital_marker' when 'city' then 'has_city_marker' else item.key end;
      p:=jsonb_populate_record(p,jsonb_build_object(column_name,value));
    end if;
  end loop;
  if p.has_capital_marker then p.province_type:='Столичная';
  elsif p.has_city_marker then p.province_type:='Городская';
  elsif p.province_type<>'Территориальная' then p.province_type:='Регион'; end if;
  update fauxlore.provinces set name=p.name,province_type=p.province_type,population=p.population,
    development=p.development,belonging=p.belonging,trade_status=p.trade_status,
    control=p.control,occupation=p.occupation,terrain_type=p.terrain_type,
    has_capital_marker=p.has_capital_marker,has_city_marker=p.has_city_marker where id=p.id;
  return fauxlore.province_payload(p);
end $$;

create or replace function fauxlore.sync_province_type_from_markers() returns trigger
language plpgsql security invoker set search_path='' as $$
declare target_id integer; target_ids integer[]; has_capital boolean; has_city boolean;
begin
  if tg_op='INSERT' then target_ids:=array[new.province_id];
  elsif tg_op='DELETE' then target_ids:=array[old.province_id];
  else target_ids:=array[old.province_id,new.province_id]; end if;
  for target_id in select distinct unnest(target_ids) loop
    select exists(select 1 from fauxlore.map_markers where province_id=target_id and type='capital'),
      exists(select 1 from fauxlore.map_markers where province_id=target_id and type='city') into has_capital,has_city;
    update fauxlore.provinces set has_capital_marker=has_capital,has_city_marker=has_city,
      province_type=case when has_capital then 'Столичная' when has_city then 'Городская'
        when province_type='Территориальная' then 'Территориальная' else 'Регион' end
      where id=target_id;
  end loop;
  return null;
end $$;
drop trigger if exists sync_province_type_from_markers on fauxlore.map_markers;
create trigger sync_province_type_from_markers after insert or update or delete on fauxlore.map_markers
for each row execute function fauxlore.sync_province_type_from_markers();

update fauxlore.provinces p set has_capital_marker=exists(select 1 from fauxlore.map_markers m where m.province_id=p.id and m.type='capital'),
  has_city_marker=exists(select 1 from fauxlore.map_markers m where m.province_id=p.id and m.type='city'),
  province_type=case when exists(select 1 from fauxlore.map_markers m where m.province_id=p.id and m.type='capital') then 'Столичная'
    when exists(select 1 from fauxlore.map_markers m where m.province_id=p.id and m.type='city') then 'Городская'
    when p.province_type='Территориальная' then 'Территориальная' else 'Регион' end
where p.kind='land';
