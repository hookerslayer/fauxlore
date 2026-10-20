-- Remove only the three explicitly retired resource categories.
-- Their province assignments were checked: all zero at the time of removal.
delete from fauxlore.province_values v using fauxlore.map_categories c
where v.layer=c.layer and v.category_id=c.id
  and c.layer='resources' and c.name in ('Бивни','Золото','Камень');
delete from fauxlore.map_categories
where layer='resources' and name in ('Бивни','Золото','Камень');
update fauxlore._settings
set value_json=to_jsonb((value_json#>>'{}')::bigint+1)
where key='data_revision';
