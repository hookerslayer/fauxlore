-- Register and enforce religious limits on treatment of other religions.
insert into fauxlore.permanent_modifier_definitions
  (source_kind,source_key,modifier_key,effect,value,unit,scope,condition_text)
values
  ('religion','Правоверие','religion_status_max','Ограничение статуса иных религий',1,'статус','Другие религии','Не выше «Невмешательство»'),
  ('religion','Стратерианство','religion_status_exclusion','Ограничение статуса иных религий',1,'статус','Другие религии','Запрещено «Истребление»'),
  ('religion','Витализм','religion_status_min','Ограничение статуса иных религий',1,'статус','Другие религии','Не ниже «Невмешательство»')
on conflict(source_kind,source_key,modifier_key) do update set
  effect=excluded.effect,value=excluded.value,unit=excluded.unit,scope=excluded.scope,condition_text=excluded.condition_text;

do $patch$
declare definition text; marker text; replacement text;
begin
  select pg_get_functiondef('fauxlore.group_status_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  marker:=$m$official_id:=case when group_kind='race' then sp.official_race_id else sp.official_religion_id end;$m$;
  replacement:=$m$official_id:=case when group_kind='race' then sp.official_race_id else sp.official_religion_id end;
  if group_kind='religion' and group_id<>official_id then
    if status_value in ('Ассимиляция','Истребление') and exists(
      select 1 from jsonb_array_elements(fauxlore.state_permanent_modifiers(sid)) m where m->>'key'='religion_status_max') then
      raise sqlstate '22023' using message='Официальная религия запрещает устанавливать статус выше «Невмешательство»';
    end if;
    if status_value='Истребление' and exists(
      select 1 from jsonb_array_elements(fauxlore.state_permanent_modifiers(sid)) m where m->>'key'='religion_status_exclusion') then
      raise sqlstate '22023' using message='Официальная религия запрещает статус «Истребление»';
    end if;
    if status_value='Признание' and exists(
      select 1 from jsonb_array_elements(fauxlore.state_permanent_modifiers(sid)) m where m->>'key'='religion_status_min') then
      raise sqlstate '22023' using message='Официальная религия запрещает устанавливать статус ниже «Невмешательство»';
    end if;
  end if;$m$;
  if position(marker in definition)=0 then raise exception 'Religious status constraint insertion point not found'; end if;
  execute replace(definition,marker,replacement);
end
$patch$;
notify pgrst,'reload schema';
