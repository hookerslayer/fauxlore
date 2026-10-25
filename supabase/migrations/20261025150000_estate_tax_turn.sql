CREATE OR REPLACE FUNCTION fauxlore.turn_api(path text, method text, body jsonb, request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a fauxlore.accounts; calendar_row fauxlore.game_calendar; previous fauxlore.operations;
  fingerprint text; result jsonb; cfg jsonb; tax_rows jsonb; state_rows jsonb; states_count integer:=0;
  province_row record; estate_line record; tax_gross numeric; tax_net numeric; tax_effects jsonb; crown_tax numeric; estate_tax numeric; status_value text;
  beneficiary_id integer; beneficiary_name text; tax_share numeric; expected_year integer; expected_turn integer; race_rate numeric; religion_rate numeric;
  report_value jsonb:='[]'::jsonb;
begin
  if path='game/calendar' and method='GET' then
    select * into calendar_row from fauxlore.game_calendar where singleton=true;
    return jsonb_build_object('year',calendar_row.year,'turn',calendar_row.turn);
  end if;
  if path<>'admin/turn/advance' or method<>'POST' or jsonb_typeof(body) is distinct from 'object' or
    body-array['expected_year','expected_turn','report']<>'{}' or
    jsonb_typeof(body->'expected_year') is distinct from 'number' or jsonb_typeof(body->'expected_turn') is distinct from 'number' then
    raise sqlstate '22023' using message='Некорректный запрос смены хода';
  end if;
  if (body->>'expected_year')!~'^\d+$' or (body->>'expected_turn')!~'^\d+$' then
    raise sqlstate '22023' using message='Ожидаемые год и ход должны быть целыми числами';
  end if;
  if body ? 'report' and (jsonb_typeof(body->'report') is distinct from 'array' or octet_length((body->'report')::text)>1500000) then
    raise sqlstate '22023' using message='Некорректный запрос смены хода';
  end if;
  expected_year:=(body->>'expected_year')::integer; expected_turn:=(body->>'expected_turn')::integer;
  a:=fauxlore.current_account();
  if a.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if request_id is null then raise sqlstate '22023' using message='Нужен идентификатор команды'; end if;
  fingerprint:=md5(jsonb_build_array(method,path,body)::text);
  perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
  select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=turn_api.request_id;
  if found then
    if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if;
    return previous.result;
  end if;
  select * into calendar_row from fauxlore.game_calendar where singleton=true for update;
  if calendar_row.year<>expected_year or calendar_row.turn<>expected_turn then
    raise sqlstate '40001' using message='Ход уже изменён в другой сессии. Обновите страницу и повторите.';
  end if;
  select config into cfg from fauxlore.economy_parameters where singleton=true for share;

  create temporary table if not exists pg_temp.turn_tax_lines(
    province_id integer, province_name text, recipient_id integer, recipient_name text,
    belonging text, gross numeric, crown numeric, estate numeric, corruption_loss numeric, crime_loss numeric, net numeric
  ) on commit drop;
  truncate pg_temp.turn_tax_lines;
  for province_row in
    select p.id,p.name,p.population,p.province_type,p.control,p.occupation,
      race.name race_name,rv.category_id race_id,religion.name religion_name,relv.category_id religion_id,owner.id owner_id,owner.name owner_name,
      occupier.id occupier_id,occupier.name occupier_name
    from fauxlore.provinces p
    left join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='races'
    left join fauxlore.map_categories race on race.layer='races' and race.id=rv.category_id
    left join fauxlore.province_values relv on relv.province_id=p.id and relv.layer='religions'
    left join fauxlore.map_categories religion on religion.layer='religions' and religion.id=relv.category_id
    left join fauxlore.province_values ov on ov.province_id=p.id and ov.layer='states'
    left join fauxlore.map_categories owner on owner.layer='states' and owner.id=ov.category_id
    left join fauxlore.map_categories occupier on occupier.layer='states' and lower(occupier.name)=lower(p.occupation)
    where p.kind='land' and (ov.category_id is not null or p.occupation is not null)
    order by p.id
  loop
    if province_row.occupation is not null and (province_row.owner_id is null or lower(province_row.occupation)<>lower(province_row.owner_name)) then
      beneficiary_id:=province_row.occupier_id; beneficiary_name:=province_row.occupier_name; tax_share:=.5;
      if beneficiary_id is null then raise sqlstate '22023' using message='Не найдено государство-оккупант провинции '||province_row.id; end if;
    else
      beneficiary_id:=province_row.owner_id; beneficiary_name:=province_row.owner_name; tax_share:=1;
    end if;
    if beneficiary_id is null then continue; end if;
    if nullif(cfg#>>array['provinceModifiers',province_row.province_type,'tax'],'') is null then
      raise sqlstate '22023' using message='Не задан налоговый коэффициент провинции '||province_row.id; end if;
    for estate_line in select * from fauxlore.province_estate_gross_tax(province_row.id,beneficiary_id,tax_share,cfg) loop
      if estate_line.gross is null then raise sqlstate '22023' using message='Не задана ставка сословия '||estate_line.estate; end if;
      tax_gross:=estate_line.gross;
      tax_effects:=fauxlore.state_tax_breakdown(tax_gross,
        (select crime from fauxlore.state_profiles where state_id=beneficiary_id),
        (select corruption from fauxlore.state_profiles where state_id=beneficiary_id),cfg);
      tax_net:=(tax_effects->>'net')::numeric;
      status_value:=fauxlore.estate_status_for(beneficiary_id,estate_line.estate);
      select crown,estate into crown_tax,estate_tax
        from fauxlore.split_province_tax(tax_net,estate_line.estate,status_value,cfg);
      insert into pg_temp.turn_tax_lines values(province_row.id,province_row.name,beneficiary_id,beneficiary_name,
        estate_line.estate,tax_gross,crown_tax,estate_tax,
        (tax_effects->>'corruption_loss')::numeric,(tax_effects->>'crime_loss')::numeric,tax_net);
    end loop;
  end loop;

  with receipts as (
    select recipient_id,'Корона'::text estate,sum(crown)::numeric(14,2) amount from pg_temp.turn_tax_lines group by recipient_id
    union all
    select recipient_id,belonging,sum(estate)::numeric(14,2) from pg_temp.turn_tax_lines where belonging<>'Отсутствует' group by recipient_id,belonging
  )
  insert into fauxlore.state_treasuries(state_id,estate,balance)
  select recipient_id,estate,amount from receipts where amount<>0
  on conflict(state_id,estate) do update set balance=fauxlore.state_treasuries.balance+excluded.balance,updated_at=now();
  update fauxlore.state_profiles sp set treasury=(select coalesce(sum(st.balance),0) from fauxlore.state_treasuries st where st.state_id=sp.state_id)
  where exists(select 1 from pg_temp.turn_tax_lines l where l.recipient_id=sp.state_id);

  select coalesce(jsonb_agg(state_report order by state_report->>'name'),'[]'::jsonb),count(*)::integer
    into report_value,states_count
  from (
    select jsonb_build_object(
      'id',s.recipient_id,'name',s.recipient_name,
      'province_count',count(distinct l.province_id),
      'gross_taxes',round(coalesce(sum(l.gross),0),2),
      'corruption_tax_loss',round(coalesce(sum(l.corruption_loss),0),2),'crime_tax_loss',round(coalesce(sum(l.crime_loss),0),2),'net_taxes',round(coalesce(sum(l.net),0),2),
      'crown_taxes',round(coalesce(sum(l.crown),0),2),
      'estate_taxes',round(coalesce(sum(l.estate),0),2),
      'tax_buckets',coalesce((select jsonb_object_agg(st.estate,round(st.balance,2)) from fauxlore.state_treasuries st where st.state_id=s.recipient_id),'{}'::jsonb),
      'opening_treasury',round(coalesce((select sum(st.balance) from fauxlore.state_treasuries st where st.state_id=s.recipient_id),0)-coalesce(sum(l.crown+l.estate),0),2),
      'closing_treasury',round(coalesce((select sum(st.balance) from fauxlore.state_treasuries st where st.state_id=s.recipient_id),0),2),
      'tax_details',coalesce(jsonb_agg(jsonb_build_object('province_id',l.province_id,'province_name',l.province_name,
        'estate',l.belonging,'gross',l.gross,'corruption_loss',l.corruption_loss,'crime_loss',l.crime_loss,'net',l.net,'crown',l.crown,'estate',l.estate) order by l.province_id)
        filter(where l.province_id is not null),'[]'::jsonb)
    ) state_report
    from (select distinct recipient_id,recipient_name from pg_temp.turn_tax_lines) s
    left join pg_temp.turn_tax_lines l on l.recipient_id=s.recipient_id
    group by s.recipient_id,s.recipient_name
  ) reports;
  insert into fauxlore.turn_economy_reports(year,turn,report,created_by)
    values(calendar_row.year,calendar_row.turn,report_value,a.id);

  -- Keep the established annual character lifecycle within this same atomic turn.
  for province_row in
    select ch.id,ch.state_id,ch.age,ch.name,ch.surname,ch.is_current_ruler,coalesce(rc.name,'') race_name
    from fauxlore.state_characters ch left join fauxlore.map_categories rc on rc.layer='races' and rc.id=ch.race_id
    where ch.alive order by ch.id for update of ch
  loop
    declare age_value integer; death_chance numeric; died boolean;
    begin
      age_value:=least(250,province_row.age+1);
      death_chance:=case
        when province_row.race_name in ('Люди','Полуэльфы','Зверолюди') then case when age_value<60 then 0 when age_value<=70 then .05 when age_value<=80 then .15 when age_value<=90 then .25 when age_value<=100 then .50 else .70 end
        when province_row.race_name='Дварфы' then case when age_value<80 then 0 when age_value<=90 then .05 when age_value<=100 then .15 when age_value<=110 then .25 when age_value<=120 then .50 else .70 end
        when province_row.race_name='Эльфы' then case when age_value<100 then 0 when age_value<=120 then .05 when age_value<=140 then .15 when age_value<=160 then .25 when age_value<=180 then .50 else .70 end
        else 0 end;
      died:=death_chance>0 and random()<death_chance;
      update fauxlore.state_characters set age=age_value,alive=not died,
        died_at_turn=case when died then calendar_row.turn else died_at_turn end,
        is_current_ruler=case when died and province_row.is_current_ruler then false else is_current_ruler end where id=province_row.id;
      if died and province_row.is_current_ruler then
        insert into fauxlore.notifications(account_id,kind,title,message)
        select recipients.account_id,'ruler_death','Умер правитель государства',
          'Правитель '||trim(province_row.name||' '||province_row.surname)||' умер в возрасте '||age_value||' лет. Требуется провести передачу власти.'
        from (
          select distinct ast.account_id from fauxlore.account_states ast where ast.layer='states' and ast.state_id=province_row.state_id
          union
          select ac.id from fauxlore.accounts ac where ac.role='admin'
            and not exists(select 1 from fauxlore.account_states ast where ast.layer='states' and ast.state_id=province_row.state_id)
        ) recipients;
      end if;
    end;
  end loop;
  update fauxlore.game_calendar set year=year+1,turn=turn+1,updated_at=now() where singleton=true returning * into calendar_row;
  result:=jsonb_build_object('year',calendar_row.year,'turn',calendar_row.turn,
    'calculated_year',calendar_row.year-1,'calculated_turn',calendar_row.turn-1,'states_calculated',states_count);
  insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,turn_api.request_id,fingerprint,result);
  return result;
end $function$
