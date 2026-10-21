alter table fauxlore.provinces
  add column belonging text not null default 'Отсутствует'
    check (belonging in ('Корона','Знать','Духовенство','Горожане','Крестьяне','Отсутствует')),
  add column trade_status text not null default 'Отсутствует'
    check (trade_status in ('Отсутствует','Устье реки','Природный порт','Центр торговли I','Центр торговли II','Центр торговли III'));

-- Assign independent, inclusive integer ranges to provinces with the three
-- requested climates. Desert and climate-free provinces keep their population.
update fauxlore.provinces p
set population = case c.name
  when 'Холодный' then 1000 + floor(random() * 2001)::bigint
  when 'Умеренный' then 3000 + floor(random() * 2001)::bigint
  when 'Тропический' then 3000 + floor(random() * 4001)::bigint
end
from fauxlore.province_values v
join fauxlore.map_categories c on c.layer = v.layer and c.id = v.category_id
where v.province_id = p.id and v.layer = 'climate'
  and c.name in ('Холодный','Умеренный','Тропический');

alter table fauxlore.provinces drop column courts;

create or replace function fauxlore.normalize(field text, value jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare t text:=nullif(btrim(value#>>'{}'),''); limit_length integer;
begin
  if field is null then raise sqlstate '22023' using message='Неизвестный параметр'; end if;
  if field in ('capital','city') then
    if jsonb_typeof(value) is distinct from 'boolean' then raise sqlstate '22023' using message='Укажите да или нет'; end if;
    return value;
  elsif field in ('population','development') then
    if value='null' and field='development' then return value; end if;
    if jsonb_typeof(value) is distinct from 'number' or t!~'^\d+$' or
      t::numeric>(case when field='population' then 2000000000 else 1000000 end) then
      raise sqlstate '22023' using message='Укажите целое неотрицательное число'; end if;
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
  elsif field<>'control' and fauxlore.layer_for(field) is null then
    raise sqlstate '22023' using message='Неизвестный параметр';
  end if;
  if value<>'null' and jsonb_typeof(value)<>'string' then raise sqlstate '22023' using message='Некорректное текстовое значение'; end if;
  limit_length:=case when field='name' then 120 when field in ('control','state') then 100 else 80 end;
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
      if item.key='control' and value<>'null' then perform fauxlore.category('states',value#>>'{}',true); end if;
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
    belonging=p.belonging,trade_status=p.trade_status,development=p.development,control=p.control,terrain_type=p.terrain_type,
    has_capital_marker=p.has_capital_marker,has_city_marker=p.has_city_marker where id=p.id;
  return fauxlore.province_payload(p);
end $$;

update fauxlore._settings set value_json=to_jsonb((value_json#>>'{}')::bigint+1) where key='data_revision';
