-- Reassign provinces before removing obsolete categories. Preserve surviving IDs/colors.
do $$
begin
  if not exists(select 1 from fauxlore.map_categories where layer='races' and name='Люди')
    or not exists(select 1 from fauxlore.map_categories where layer='religions' and name='Правоверие') then
    raise exception 'Missing destination race or religion';
  end if;
end $$;

update fauxlore.province_values v set category_id=destination.id
from fauxlore.map_categories source, fauxlore.map_categories destination
where v.layer=source.layer and v.category_id=source.id
  and destination.layer=source.layer
  and ((source.layer='races' and source.name='Гоблины' and destination.name='Люди')
    or (source.layer='religions' and source.name='Утонувший' and destination.name='Правоверие'));

delete from fauxlore.map_categories
where (layer='races' and name='Гоблины') or (layer='religions' and name='Утонувший');

update fauxlore.map_categories set name='Полуэльфы' where layer='races' and name='Гномы';

update fauxlore._settings
set value_json=to_jsonb((value_json#>>'{}')::bigint+1)
where key='data_revision';
