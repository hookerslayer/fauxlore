-- Archive legacy province estate ownership and retire its mutators before dropping the column.
create table if not exists fauxlore.retired_province_belonging (province_id integer primary key, belonging text not null, archived_at timestamptz not null default now());
insert into fauxlore.retired_province_belonging(province_id,belonging) select id,belonging from fauxlore.provinces on conflict (province_id) do nothing;
drop trigger if exists provinces_enforce_belonging on fauxlore.provinces;
drop trigger if exists province_values_crown_acquisition on fauxlore.province_values;
drop trigger if exists state_application_allocate_belonging on fauxlore.state_applications;
drop function if exists fauxlore.enforce_province_belonging();
drop function if exists fauxlore.assign_acquired_province_to_crown();
drop function if exists fauxlore.allocate_new_state_belonging();
drop function if exists fauxlore.province_belonging_api(text,text,jsonb,uuid);
CREATE OR REPLACE FUNCTION fauxlore.edit_province(province_id integer, changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
  else p.province_type:='Регион'; end if;
  update fauxlore.provinces set name=p.name,province_type=p.province_type,population=p.population,
    development=p.development,trade_status=p.trade_status,
    control=p.control,occupation=p.occupation,terrain_type=p.terrain_type,
    has_capital_marker=p.has_capital_marker,has_city_marker=p.has_city_marker where id=p.id;
  return fauxlore.province_payload(p);
end $function$
;

CREATE OR REPLACE FUNCTION fauxlore.game_state_api(path text, method text, body jsonb, request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a fauxlore.accounts; state_value integer; state_name text; result jsonb;
  previous fauxlore.operations; fingerprint text; province_count integer; removed_assignments integer; unlinked_markers integer;
begin
  if jsonb_typeof(body) is distinct from 'object' then raise sqlstate '22023' using message='Некорректный запрос'; end if;
  a:=fauxlore.current_account();
  if path='my/states' and method='GET' then
    select coalesce(jsonb_agg(item order by item->>'name'),'[]'::jsonb) into result from (
      select jsonb_build_object(
        'id',c.id,'name',c.name,'color',c.color,'is_npc',coalesce(sp.is_npc,true),
        'form_name',sp.government_name,'principles',sp.principles,
        'official_race',(select name from fauxlore.map_categories where layer='races' and id=sp.official_race_id),
        'official_religion',(select name from fauxlore.map_categories where layer='religions' and id=sp.official_religion_id),
        'corruption',coalesce(sp.corruption,0.2),'crime',coalesce(sp.crime,0.2),
        'province_count',(select count(*) from fauxlore.province_values v join fauxlore.provinces p on p.id=v.province_id where v.layer='states' and v.category_id=c.id and p.kind='land'),
        'population',(select coalesce(sum(p.population),0) from fauxlore.province_values v join fauxlore.provinces p on p.id=v.province_id where v.layer='states' and v.category_id=c.id and p.kind='land'),
        'taxes',(select coalesce(sum(p.taxes),0) from fauxlore.province_values v join fauxlore.provinces p on p.id=v.province_id where v.layer='states' and v.category_id=c.id and p.kind='land'),
        'provinces',coalesce((select jsonb_agg(jsonb_build_object(
          'id',p.id,'name',p.name,'kind',p.kind,'area',p.area,'province_type',p.province_type,'population',p.population,'development',p.development,
          'trade_status',p.trade_status,'control',p.control,'occupation',p.occupation,'taxes',p.taxes,'production',p.production,
          'race',(select rc.name from fauxlore.province_values rv join fauxlore.map_categories rc on rc.layer=rv.layer and rc.id=rv.category_id where rv.province_id=p.id and rv.layer='races'),
          'religion',(select rc.name from fauxlore.province_values rv join fauxlore.map_categories rc on rc.layer=rv.layer and rc.id=rv.category_id where rv.province_id=p.id and rv.layer='religions'),
          'resource',(select rc.name from fauxlore.province_values rv join fauxlore.map_categories rc on rc.layer=rv.layer and rc.id=rv.category_id where rv.province_id=p.id and rv.layer='resources')
        ) order by p.id) from fauxlore.province_values v join fauxlore.provinces p on p.id=v.province_id
        where v.layer='states' and v.category_id=c.id and p.kind='land'),'[]'::jsonb)
      ) as item
      from fauxlore.account_states ast join fauxlore.map_categories c on c.layer='states' and c.id=ast.state_id
      left join fauxlore.state_profiles sp on sp.state_id=c.id where ast.account_id=a.id
    ) owned;
    return result;
  end if;
  if path !~ '^admin/states/[0-9]+$' or method<>'DELETE' then raise sqlstate '22023' using message='Некорректный запрос'; end if;
  if a.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if request_id is null then raise sqlstate '22023' using message='Нужен идентификатор команды'; end if;
  if body<>'{}'::jsonb then raise sqlstate '22023' using message='Удаление государства не принимает параметры'; end if;
  state_value:=split_part(path,'/',3)::integer; fingerprint:=md5(jsonb_build_array(method,path,body)::text);
  perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
  select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=game_state_api.request_id;
  if found then
    if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if;
    return previous.result;
  end if;
  select name into state_name from fauxlore.map_categories where layer='states' and id=state_value for update;
  if not found then raise sqlstate 'P0002' using message='Государство не найдено'; end if;
  update fauxlore.map_markers set state_id=null where state_id=state_value; get diagnostics unlinked_markers=row_count;
  delete from fauxlore.province_values where layer='states' and category_id=state_value; get diagnostics removed_assignments=row_count;
  select count(*) into province_count from fauxlore.province_values where layer='states' and category_id=state_value;
  delete from fauxlore.account_states where layer='states' and state_id=state_value;
  delete from fauxlore.state_profiles where state_id=state_value;
  delete from fauxlore.map_categories where layer='states' and id=state_value;
  update fauxlore._settings set value_json=to_jsonb((value_json#>>'{}')::bigint+1) where key='data_revision';
  result:=jsonb_build_object('id',state_value,'name',state_name,'deleted',true,'removed_province_assignments',removed_assignments,'unlinked_markers',unlinked_markers,'remaining_assignments',province_count);
  insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,game_state_api.request_id,fingerprint,result);
  return result;
end $function$
;

CREATE OR REPLACE FUNCTION fauxlore."normalize"(field text, value jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
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
  elsif field='trade_status' then
    if t is null or t not in ('Отсутствует','Устье реки','Природный порт','Центр торговли I','Центр торговли II','Центр торговли III') then raise sqlstate '22023' using message='Неизвестный торговый статус'; end if;
  elsif field='province_type' then
    raise sqlstate '22023' using message='Тип провинции определяется автоматически';
  elsif field='terrain_type' then
    if value='null' then return value; end if;
    if t is null or t not in ('forest','marsh','plains','hills','mountains','high_mountains') then raise sqlstate '22023' using message='Неизвестный тип местности'; end if;
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
end $function$
;

CREATE OR REPLACE FUNCTION fauxlore.prepare_local_marriage_candidate()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare generated jsonb; sp fauxlore.state_profiles; estate_name text; options text[]; selected_estate text;
  total_weight numeric:=0; estate_weight numeric; roll numeric; cumulative numeric:=0;
begin
  generated:=fauxlore.generate_character_name(new.race_id,new.gender);
  new.name:=generated->>'name'; new.surname:=generated->>'surname';
  select * into sp from fauxlore.state_profiles where state_id=new.state_id;
  options:=array(select x.estate from unnest(array['Знать','Духовенство','Горожане','Крестьяне']) as x(estate) where fauxlore.estate_status_for(new.state_id,x.estate)='Ключевое');
  foreach estate_name in array options loop
    select coalesce(sum(fauxlore.province_value_for_state(p.id,new.state_id) * coalesce((select ep.population from fauxlore.estate_population(p.province_type,p.population::bigint) ep where ep.estate=estate_name),0)::numeric / greatest(coalesce(p.population,0),1)),0) into estate_weight
    from fauxlore.province_values sv join fauxlore.provinces p on p.id=sv.province_id and p.kind='land'
    where sv.layer='states' and sv.category_id=new.state_id ;
    total_weight:=total_weight+greatest(estate_weight,0);
  end loop;
  if cardinality(options)>0 then
    if total_weight<=0 then total_weight:=cardinality(options); roll:=random()*total_weight;
    else roll:=random()*total_weight; end if;
    foreach estate_name in array options loop
      select coalesce(sum(fauxlore.province_value_for_state(p.id,new.state_id) * coalesce((select ep.population from fauxlore.estate_population(p.province_type,p.population::bigint) ep where ep.estate=estate_name),0)::numeric / greatest(coalesce(p.population,0),1)),0) into estate_weight
      from fauxlore.province_values sv join fauxlore.provinces p on p.id=sv.province_id and p.kind='land'
      where sv.layer='states' and sv.category_id=new.state_id ;
      if estate_weight<=0 and total_weight=cardinality(options) then estate_weight:=1; end if;
      cumulative:=cumulative+greatest(estate_weight,0);
      if roll<cumulative then selected_estate:=estate_name; exit; end if;
    end loop;
  end if;
  new.supported_by:=case when selected_estate is null then '{}'::text[] else array[selected_estate] end;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION fauxlore.prepare_succession_support()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare candidate jsonb; prepared jsonb:='[]'::jsonb; support_map jsonb:='{}'::jsonb; assignments jsonb:='{}'::jsonb;
  estate_name text; i integer; chosen_slot integer; estate_weight numeric; support_weight numeric;
  province_votes integer[]:=array[0,0,0]; authority_value text; is_key boolean;
begin
  perform fauxlore.ensure_state_group_politics(new.state_id);
  authority_value:=new.authority;
  if authority_value='Вече' then
    for i in select 1+floor(random()*3)::int from fauxlore.province_values where layer='states' and category_id=new.state_id loop
      province_votes[i]:=province_votes[i]+1;
    end loop;
  else
    for estate_name in select unnest(array['Знать','Духовенство','Горожане','Крестьяне']) loop
      is_key:=fauxlore.estate_status_for(new.state_id,estate_name)='Ключевое';
      if authority_value='Клир' and estate_name<>'Духовенство' then continue; end if;
      if authority_value in ('Династия','Диктат') and not is_key then continue; end if;
      select coalesce(sum(fauxlore.province_value_for_state(p.id,new.state_id) * coalesce((select ep.population from fauxlore.estate_population(p.province_type,p.population::bigint) ep where ep.estate=estate_name),0)::numeric / greatest(coalesce(p.population,0),1)),0) into estate_weight
        from fauxlore.province_values s join fauxlore.provinces p on p.id=s.province_id and p.kind='land'
        where s.layer='states' and s.category_id=new.state_id ;
      if estate_weight<=0 then estate_weight:=1; end if;
      assignments:=jsonb_set(assignments,array[estate_name],to_jsonb(1+floor(random()*3)::int),true);
    end loop;
  end if;
  for i in 0..jsonb_array_length(new.candidates)-1 loop
    candidate:=new.candidates->i;
    if authority_value='Вече' then
      candidate:=jsonb_set(candidate,'{support_votes}',to_jsonb(province_votes[i+1]),true);
    else
      support_map:='{}'::jsonb; support_weight:=0;
      for estate_name in select key from jsonb_each(assignments) loop
        chosen_slot:=(assignments->>estate_name)::integer;
        support_map:=support_map||jsonb_build_object(estate_name,chosen_slot=i+1);
        if chosen_slot=i+1 then
          select coalesce(sum(fauxlore.province_value_for_state(p.id,new.state_id) * coalesce((select ep.population from fauxlore.estate_population(p.province_type,p.population::bigint) ep where ep.estate=estate_name),0)::numeric / greatest(coalesce(p.population,0),1)),0) into estate_weight
            from fauxlore.province_values s join fauxlore.provinces p on p.id=s.province_id and p.kind='land'
            where s.layer='states' and s.category_id=new.state_id ;
          support_weight:=support_weight+greatest(estate_weight,1);
        end if;
      end loop;
      candidate:=jsonb_set(candidate,'{support}',support_map,true);
      candidate:=jsonb_set(candidate,'{support_weight}',to_jsonb(support_weight),true);
    end if;
    prepared:=prepared||jsonb_build_array(candidate);
  end loop;
  new.candidates:=prepared;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION fauxlore.resolve_designated_dictator()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare event_row fauxlore.state_succession_events; sp fauxlore.state_profiles; designee fauxlore.state_characters;
  candidate jsonb; total_key_weight numeric; support_weight numeric; is_supported boolean;
begin
  if not old.alive or new.alive or not old.is_current_ruler then return new; end if;
  select * into sp from fauxlore.state_profiles where state_id=old.state_id and principles->>'authority'='Диктат' and designated_successor_id is not null;
  if not found then return new; end if;
  select * into designee from fauxlore.state_characters where id=sp.designated_successor_id and state_id=old.state_id and alive and age>=16;
  if not found then return new; end if;
  select * into event_row from fauxlore.state_succession_events where state_id=old.state_id and resolved_at is null order by id desc limit 1 for update;
  if not found then return new; end if;
  candidate:=event_row.candidates->0;
  candidate:=candidate||jsonb_build_object('name',designee.name,'surname',designee.surname,'gender',designee.gender,'age',designee.age,
    'race_id',designee.race_id,'religion_id',designee.religion_id,'race',(select name from fauxlore.map_categories where layer='races' and id=designee.race_id),
    'religion',(select name from fauxlore.map_categories where layer='religions' and id=designee.religion_id),'designated',true);
  update fauxlore.state_succession_events set candidates=jsonb_set(candidates,'{0}',candidate,true) where id=event_row.id returning * into event_row;
  select coalesce(sum(fauxlore.province_value_for_state(p.id,old.state_id) * coalesce((select ep.population from fauxlore.estate_population(p.province_type,p.population::bigint) ep where ep.estate=estate_name),0)::numeric / greatest(coalesce(p.population,0),1)),0) into total_key_weight
    from fauxlore.province_values s join fauxlore.provinces p on p.id=s.province_id and p.kind='land'
    cross join lateral unnest(array['Знать','Духовенство','Горожане','Крестьяне']) estate_name
    where s.layer='states' and s.category_id=old.state_id and fauxlore.estate_status_for(old.state_id,estate_name)='Ключевое';
  support_weight:=coalesce((candidate->>'support_weight')::numeric,0);
  is_supported:=total_key_weight>0 and support_weight>total_key_weight/2;
  if not is_supported then return new; end if;
  update fauxlore.state_characters set is_current_ruler=false where state_id=old.state_id and is_current_ruler;
  update fauxlore.state_characters set is_current_ruler=true where id=designee.id;
  perform fauxlore.apply_ruler_change_effects(old.state_id,designee.race_id,designee.religion_id);
  update fauxlore.state_profiles set prestige=10,ruler_name=designee.name,ruler_surname=designee.surname,ruler_gender=designee.gender,
    ruler_title=designee.title,ruler_age=designee.age,
    term_started_turn=(select turn from fauxlore.game_calendar where singleton),designated_heir_id=null,designated_successor_id=null where state_id=old.state_id;
  update fauxlore.state_succession_events set chosen_candidate=candidate,chosen_at=now(),resolved_at=now() where id=event_row.id;
  update fauxlore.notifications n set title='Назначенный преемник вступил во власть',message=designee.name||' '||designee.surname||' получил(а) поддержку большинства влияния ключевых сословий и немедленно вступил(а) в должность.'
    where n.kind='succession' and n.title='Требуется передача власти' and n.created_at>now()-interval '1 minute'
      and n.account_id in (
        select ast.account_id from fauxlore.account_states ast where ast.layer='states' and ast.state_id=old.state_id
        union select ac.id from fauxlore.accounts ac where ac.role='admin'
          and not exists(select 1 from fauxlore.account_states ast where ast.layer='states' and ast.state_id=old.state_id)
      );
  return new;
end $function$
;

alter table fauxlore.provinces drop column belonging;
