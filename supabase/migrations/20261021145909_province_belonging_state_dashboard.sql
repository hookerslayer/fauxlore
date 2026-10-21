-- Persist belonging/trade status on province edits and expose the fields used
-- by the state province table. Mirrored in supabase/schema.sql.
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
      if item.key='occupation' and value<>'null' then perform fauxlore.category('states',value#>>'{}',false); end if;
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
    development=p.development,belonging=p.belonging,trade_status=p.trade_status,
    control=p.control,occupation=p.occupation,terrain_type=p.terrain_type,
    has_capital_marker=p.has_capital_marker,has_city_marker=p.has_city_marker where id=p.id;
  return fauxlore.province_payload(p);
end $$;

create or replace function fauxlore.game_state_api(path text, method text, body jsonb, request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
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
          'belonging',p.belonging,'trade_status',p.trade_status,'control',p.control,'occupation',p.occupation,'taxes',p.taxes,'production',p.production,
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
end $$;
revoke all on function fauxlore.game_state_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.game_state_api(text,text,jsonb,uuid) to anon,authenticated;
