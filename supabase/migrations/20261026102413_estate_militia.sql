-- Estate militia: server-side preview, judge approval, annual service and disbanding.
alter table fauxlore.military_formations drop constraint military_formations_kind_check;
alter table fauxlore.military_formations add constraint military_formations_kind_check
  check (kind in ('regular','mercenary','militia'));

create table fauxlore.militia_settings (
  singleton boolean primary key default true check (singleton),
  coefficient numeric(6,3) not null default 1 check (coefficient between 0 and 10)
);
insert into fauxlore.militia_settings(singleton,coefficient) values (true,1);
create table fauxlore.militia_calls (
  state_id integer primary key references fauxlore.state_profiles(state_id) on delete cascade,
  status text not null check (status in ('pending','approved','active','rejected','disbanded')),
  requested_turn integer not null,
  approved_turn integer,
  disbanded_turn integer,
  doctrine text not null,
  formation_id bigint references fauxlore.military_formations(id) on delete set null,
  plan jsonb not null default '{}'::jsonb,
  loyalty_targets jsonb not null default '{}'::jsonb,
  loyalty_debt jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
create table fauxlore.militia_sources (
  state_id integer not null references fauxlore.militia_calls(state_id) on delete cascade,
  province_id integer not null references fauxlore.provinces(id),
  estate text not null check (estate in ('Крестьяне','Горожане','Знать','Духовенство')),
  quantity integer not null check (quantity>0),
  primary key(state_id,province_id,estate)
);
alter table fauxlore.militia_settings enable row level security;
alter table fauxlore.militia_calls enable row level security;
alter table fauxlore.militia_sources enable row level security;
revoke all on fauxlore.militia_settings,fauxlore.militia_calls,fauxlore.militia_sources from public,anon,authenticated;
create table fauxlore.militia_charges (
  id bigint generated always as identity primary key,
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  estate text not null check (estate in ('Корона','Знать','Горожане','Крестьяне')),
  year integer not null,
  turn integer not null,
  amount bigint not null check (amount>=0),
  created_at timestamptz not null default now(),
  unique(state_id,estate,year,turn)
);
alter table fauxlore.militia_charges enable row level security;
revoke all on fauxlore.militia_charges from public,anon,authenticated;

create or replace function fauxlore.militia_preview(state_key integer)
returns jsonb language plpgsql stable security definer set search_path='' as $function$
declare doctrine_value text; coeff numeric; state_name text; province_row record; estate_row record;
  avg_loyalty numeric; rate numeric; status_factor numeric; count_value integer; province_total integer;
  grand_total integer:=0; sources jsonb:='[]'::jsonb; province_list jsonb:='[]'::jsonb;
  contributions jsonb:='{}'::jsonb; units jsonb:='{}'::jsonb; province_units jsonb;
  unit_row record; unit_names text[]; shares numeric[];
begin
  select sp.principles->>'military',c.name into doctrine_value,state_name
    from fauxlore.state_profiles sp join fauxlore.map_categories c on c.id=sp.state_id and c.layer='states'
    where sp.state_id=state_key;
  if doctrine_value is null then raise sqlstate '22023' using message='Военная доктрина не задана'; end if;
  select coefficient into coeff from fauxlore.militia_settings where singleton;
  if doctrine_value='Фирд' then
    unit_names:=array['Копейщик','Лучник','Сержант','Всадник']; shares:=array[.65,.25,.05,.05];
  elsif doctrine_value='Сословная армия' then
    unit_names:=array['Копейщик','Лучник','Сержант','Всадник','Конный сержант','Рыцарь'];
    shares:=array[.20,.10,.10,.10,.20,.30];
  else
    unit_names:=array['Сержант','Пикинёр','Арбалетчик','Всадник']; shares:=array[.30,.30,.35,.05];
  end if;
  for province_row in
    select p.* from fauxlore.provinces p join fauxlore.province_values v on v.province_id=p.id
      and v.layer='states' and v.category_id=state_key
    where p.kind='land' and (p.occupation is null or lower(p.occupation)=lower(state_name))
    order by p.id
  loop
    select coalesce(avg(coalesce(g.loyalty,.5)),.5) into avg_loyalty
      from fauxlore.estate_population(province_row.province_type,province_row.population) ep
      left join fauxlore.state_group_politics g on g.state_id=state_key and g.group_type='estate' and g.group_key=ep.estate
      where ep.population>0;
    province_total:=0;
    for estate_row in
      select ep.estate,ep.population,coalesce(g.status,fauxlore.estate_status_for(state_key,ep.estate)) status
      from fauxlore.estate_population(province_row.province_type,province_row.population) ep
      left join fauxlore.state_group_politics g on g.state_id=state_key and g.group_type='estate' and g.group_key=ep.estate
    loop
      rate:=case doctrine_value
        when 'Фирд' then case estate_row.estate when 'Крестьяне' then .18 when 'Горожане' then .12 when 'Знать' then .03 else .01 end
        when 'Сословная армия' then case estate_row.estate when 'Крестьяне' then .04 when 'Горожане' then .06 when 'Знать' then .45 else .02 end
        when 'Гвардия' then case estate_row.estate when 'Крестьяне' then .01 when 'Горожане' then .02 when 'Знать' then .08 else .01 end
        else case estate_row.estate when 'Крестьяне' then .01 when 'Горожане' then .03 when 'Знать' then .05 else .01 end end;
      status_factor:=case estate_row.status when 'Ключевое' then 1.25 when 'Бесправное' then .4 else 1 end;
      count_value:=floor(estate_row.population*rate*status_factor*(.5+avg_loyalty/2)
        *greatest(0,least(100,coalesce(province_row.control,100)))/100*coeff);
      if count_value>0 then
        province_total:=province_total+count_value;
        sources:=sources||jsonb_build_array(jsonb_build_object('province_id',province_row.id,'estate',estate_row.estate,'quantity',count_value));
        contributions:=jsonb_set(contributions,array[estate_row.estate],to_jsonb(coalesce((contributions->>estate_row.estate)::integer,0)+count_value));
      end if;
    end loop;
    if province_total>0 then
      select jsonb_object_agg(name,quantity order by ord) into province_units from (
        select name,ord,base+case when row_number() over(order by fractional desc,ord)
          <=province_total-sum(base) over() then 1 else 0 end quantity
        from (
          select unit_names[i] name,i ord,floor(province_total*shares[i])::integer base,
            province_total*shares[i]-floor(province_total*shares[i]) fractional
          from generate_subscripts(unit_names,1) i
        ) allocation
      ) distributed;
      for unit_row in select key,value from jsonb_each_text(province_units) loop
        units:=jsonb_set(units,array[unit_row.key],to_jsonb(coalesce((units->>unit_row.key)::integer,0)+unit_row.value::integer));
      end loop;
      province_list:=province_list||jsonb_build_array(jsonb_build_object('province_id',province_row.id,'name',province_row.name,'total',province_total,'units',province_units));
      grand_total:=grand_total+province_total;
    end if;
  end loop;
  return jsonb_build_object('doctrine',doctrine_value,'coefficient',coeff,'total',grand_total,
    'provinces',province_list,'sources',sources,'contributions',contributions,'units',units);
end $function$;
revoke all on function fauxlore.militia_preview(integer) from public,anon,authenticated;

create or replace function public.militia_api(action text,target_state integer default null,payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; sid integer; turn_value integer; call_row fauxlore.militia_calls;
  plan_value jsonb; formation_key bigint; survivor_count integer; origin_count integer; returned integer;
  source_row record; unit_row record; total_cost numeric; default_state_name text;
begin
  actor:=fauxlore.current_account();
  if actor.id is null then raise sqlstate '42501' using message='Требуется авторизация'; end if;
  if action='admin_queue' then
    if actor.role<>'admin' then raise sqlstate '42501' using message='Доступно только администратору'; end if;
    return jsonb_build_object('requests',coalesce((select jsonb_agg(to_jsonb(m)||jsonb_build_object('state_name',c.name) order by m.updated_at)
      from fauxlore.militia_calls m join fauxlore.map_categories c on c.layer='states' and c.id=m.state_id
      where m.status='pending'),'[]'::jsonb));
  end if;
  if action='settings' or action='set_coefficient' then
    if actor.role<>'admin' then raise sqlstate '42501' using message='Доступно только администратору'; end if;
    if action='set_coefficient' then
      if jsonb_typeof(payload->'coefficient') is distinct from 'number' or
        (payload->>'coefficient')::numeric not between 0 and 10 then
        raise sqlstate '22023' using message='Коэффициент должен быть от 0 до 10'; end if;
      update fauxlore.militia_settings set coefficient=(payload->>'coefficient')::numeric where singleton;
    end if;
    return jsonb_build_object('coefficient',(select coefficient from fauxlore.militia_settings where singleton));
  end if;
  sid:=coalesce(target_state,(select state_id from fauxlore.account_states where account_id=actor.id order by state_id limit 1));
  if sid is null or (actor.role<>'admin' and not exists(select 1 from fauxlore.account_states where account_id=actor.id and state_id=sid)) then
    raise sqlstate '42501' using message='Нет доступа к государству'; end if;
  select turn into turn_value from fauxlore.game_calendar where singleton;
  if action='snapshot' then
    return jsonb_build_object('state_id',sid,'turn',turn_value,'preview',fauxlore.militia_preview(sid),
      'call',(select to_jsonb(m) from fauxlore.militia_calls m where m.state_id=sid));
  end if;
  perform 1 from fauxlore.state_profiles where state_id=sid for update;
  select * into call_row from fauxlore.militia_calls where state_id=sid for update;
  if action='request' then
    if call_row.status in ('pending','approved','active') then raise sqlstate '22023' using message='Ополчение уже созвано или ожидает решения'; end if;
    if call_row.status='disbanded' and turn_value<=call_row.disbanded_turn then
      raise sqlstate '22023' using message='Повторный созыв доступен после завершения хода роспуска'; end if;
    plan_value:=fauxlore.militia_preview(sid);
    if (plan_value->>'total')::integer<1 then raise sqlstate '22023' using message='Нет доступного мобилизационного пула'; end if;
    insert into fauxlore.militia_calls(state_id,status,requested_turn,approved_turn,disbanded_turn,doctrine,formation_id,plan,updated_at)
      values(sid,'pending',turn_value,null,null,plan_value->>'doctrine',null,plan_value,now())
      on conflict(state_id) do update set status='pending',requested_turn=excluded.requested_turn,
        approved_turn=null,disbanded_turn=null,doctrine=excluded.doctrine,formation_id=null,plan=excluded.plan,updated_at=now();
    insert into fauxlore.notifications(account_id,kind,title,message)
      select id,'military','Созыв ополчения ожидает решения','Проверьте заявку во вкладке профиля «Военные решения судьи».'
      from fauxlore.accounts where role='admin';
    return jsonb_build_object('status','pending');
  elsif action='decide' then
    if actor.role<>'admin' then raise sqlstate '42501' using message='Доступно только администратору'; end if;
    if call_row.status is distinct from 'pending' then raise sqlstate '22023' using message='Заявка не ожидает решения'; end if;
    if payload->>'decision' not in ('approve','reject') then raise sqlstate '22023' using message='Неизвестное решение'; end if;
    update fauxlore.militia_calls set status=case when payload->>'decision'='approve' then 'approved' else 'rejected' end,
      approved_turn=case when payload->>'decision'='approve' then turn_value else null end,updated_at=now() where state_id=sid;
    insert into fauxlore.notifications(account_id,kind,title,message)
      select account_id,'military','Решение по ополчению',
        case when payload->>'decision'='approve' then 'Созыв разрешён. Ополчение появится в следующий ход.' else 'Созыв отклонён.' end
      from fauxlore.account_states where state_id=sid;
    return jsonb_build_object('status',case when payload->>'decision'='approve' then 'approved' else 'rejected' end);
  elsif action='disband' then
    if call_row.status<>'active' then raise sqlstate '22023' using message='Нет созванного ополчения'; end if;
    select coalesce(sum(fu.quantity),0) into survivor_count from fauxlore.military_formation_units fu
      where fu.formation_id=call_row.formation_id;
    select coalesce(sum(quantity),0) into origin_count from fauxlore.militia_sources where state_id=sid;
    survivor_count:=least(survivor_count,origin_count);
    for source_row in
      with allocations as (
        select s.province_id,s.estate,s.quantity,
          floor(s.quantity::numeric*survivor_count/greatest(origin_count,1))::integer base,
          s.quantity::numeric*survivor_count/greatest(origin_count,1)
            -floor(s.quantity::numeric*survivor_count/greatest(origin_count,1)) fractional
        from fauxlore.militia_sources s where s.state_id=sid
      ), ranked as (
        select *,row_number() over(order by fractional desc,province_id,estate) rank,
          sum(base) over() base_total from allocations
      )
      select province_id,base+case when rank<=survivor_count-base_total then 1 else 0 end survivors from ranked
    loop
      update fauxlore.provinces set population=population+source_row.survivors where id=source_row.province_id;
    end loop;
    update fauxlore.military_formations set active=false where id=call_row.formation_id and state_id=sid and kind='militia';
    delete from fauxlore.militia_sources where state_id=sid;
    update fauxlore.militia_calls set status='disbanded',disbanded_turn=turn_value,updated_at=now() where state_id=sid;
    return jsonb_build_object('status','disbanded','survivors_returned',survivor_count,'losses',origin_count-survivor_count);
  end if;
  raise sqlstate '22023' using message='Неизвестная операция ополчения';
end $function$;
revoke all on function public.militia_api(text,integer,jsonb) from public,anon;
grant execute on function public.militia_api(text,integer,jsonb) to authenticated;

-- The existing regular-army charge must not also bill militia to the Crown.
do $migration$
declare definition text; before_text text; after_text text;
begin
  definition:=pg_get_functiondef('fauxlore.charge_army_upkeep_before_turn()'::regprocedure);
  before_text:='where f.state_id=state_row.state_id and f.active order by f.id loop';
  after_text:='where f.state_id=state_row.state_id and f.active and f.kind<>''militia'' order by f.id loop';
  if position(before_text in definition)=0 then raise exception 'Regular army charge insertion point missing'; end if;
  execute replace(definition,before_text,after_text);
end $migration$;

create or replace function fauxlore.charge_militia_before_turn()
returns trigger language plpgsql security definer set search_path='' as $function$
declare militia_row fauxlore.militia_calls; total_cost bigint; crown_cost bigint;
  burgher_cost bigint; peasant_cost bigint; noble_cost bigint; burgher_count integer; peasant_count integer;
  charge_row record; report_value jsonb;
begin
  if new.turn=old.turn then return new; end if;
  for militia_row in select * from fauxlore.militia_calls where status='active' order by state_id loop
    select floor(coalesce(sum(fu.quantity::numeric*u.upkeep),0))::bigint into total_cost
      from fauxlore.military_formation_units fu join fauxlore.military_unit_catalog u on u.id=fu.unit_id
      where fu.formation_id=militia_row.formation_id;
    crown_cost:=total_cost;burgher_cost:=0;peasant_cost:=0;noble_cost:=0;
    if militia_row.doctrine='Фирд' then
      burgher_count:=coalesce((militia_row.plan#>>'{contributions,Горожане}')::integer,0);
      peasant_count:=coalesce((militia_row.plan#>>'{contributions,Крестьяне}')::integer,0);
      if burgher_count+peasant_count>0 then
        burgher_cost:=floor(total_cost*.6*burgher_count/(burgher_count+peasant_count));
        peasant_cost:=floor(total_cost*.6*peasant_count/(burgher_count+peasant_count));
      end if;
    elsif militia_row.doctrine='Сословная армия' then
      noble_cost:=floor(total_cost*.7);
    end if;
    crown_cost:=total_cost-burgher_cost-peasant_cost-noble_cost;
    for charge_row in select estate,amount from (values
      ('Корона'::text,crown_cost),('Горожане',burgher_cost),
      ('Крестьяне',peasant_cost),('Знать',noble_cost)) v(estate,amount) where amount>0 loop
      update fauxlore.state_treasuries set balance=balance-charge_row.amount,updated_at=now()
        where state_id=militia_row.state_id and estate=charge_row.estate;
      insert into fauxlore.militia_charges(state_id,estate,year,turn,amount)
        values(militia_row.state_id,charge_row.estate,old.year,old.turn,charge_row.amount);
    end loop;
    update fauxlore.state_profiles set treasury=(select sum(balance) from fauxlore.state_treasuries where state_id=militia_row.state_id)
      where state_id=militia_row.state_id;
    update fauxlore.turn_economy_reports set report=(
      select jsonb_agg(case when (entry.value->>'id')::integer=militia_row.state_id then
        entry.value||jsonb_build_object('militia_upkeep',total_cost,
          'army_upkeep',coalesce((entry.value->>'army_upkeep')::numeric,0)+total_cost,
          'closing_treasury',(select sum(balance) from fauxlore.state_treasuries where state_id=militia_row.state_id),
          'tax_buckets',coalesce(entry.value->'tax_buckets','{}'::jsonb)||
            (select jsonb_object_agg(estate,balance) from fauxlore.state_treasuries where state_id=militia_row.state_id))
        else entry.value end order by entry.ord)
      from jsonb_array_elements(report) with ordinality entry(value,ord))
      where year=old.year and turn=old.turn;
  end loop;
  return new;
end $function$;
revoke all on function fauxlore.charge_militia_before_turn() from public,anon,authenticated;
create trigger game_calendar_militia_upkeep before update of year,turn on fauxlore.game_calendar
  for each row execute function fauxlore.charge_militia_before_turn();

create or replace function fauxlore.advance_militia_turn()
returns trigger language plpgsql security definer set search_path='' as $function$
declare militia_row fauxlore.militia_calls; plan_value jsonb; source_row record; unit_row record;
  home_province integer; formation_key bigint; state_name text; loyalty_entry record;
  current_loyalty numeric; remaining numeric; baseline numeric; restoration numeric;
begin
  if new.turn=old.turn then return new; end if;
  for militia_row in select * from fauxlore.militia_calls where status='approved' and approved_turn<new.turn order by state_id loop
    plan_value:=fauxlore.militia_preview(militia_row.state_id);
    if (plan_value->>'total')::integer<1 then
      update fauxlore.militia_calls set status='rejected',updated_at=now() where state_id=militia_row.state_id;
      insert into fauxlore.notifications(account_id,kind,title,message)
        select account_id,'military','Созыв ополчения отменён','К началу хода доступный мобилизационный пул стал пустым.'
        from fauxlore.account_states where state_id=militia_row.state_id;
      continue;
    end if;
    select name into state_name from fauxlore.map_categories where layer='states' and id=militia_row.state_id;
    select p.id into home_province from fauxlore.provinces p
      join fauxlore.province_values v on v.province_id=p.id and v.layer='states' and v.category_id=militia_row.state_id
      where p.kind='land' and (p.occupation is null or lower(p.occupation)=lower(state_name))
      order by case when exists(select 1 from fauxlore.map_markers m where m.province_id=p.id and m.type='capital') then 0
        when exists(select 1 from fauxlore.map_markers m where m.province_id=p.id and m.type='city') then 1 else 2 end,p.id limit 1;
    if home_province is null then
      update fauxlore.militia_calls set status='rejected',updated_at=now() where state_id=militia_row.state_id;
      continue;
    end if;
    insert into fauxlore.military_formations(state_id,name,domain,kind,province_id)
      values(militia_row.state_id,'Сословное ополчение','land','militia',home_province) returning id into formation_key;
    for unit_row in select key,value::integer quantity from jsonb_each_text(plan_value->'units') loop
      if unit_row.quantity>0 then
        insert into fauxlore.military_formation_units(formation_id,unit_id,quantity)
          select formation_key,u.id,unit_row.quantity from fauxlore.military_unit_catalog u
          where u.name=unit_row.key and u.state_id is null and u.active order by u.version desc limit 1;
        if not found then raise exception 'Militia unit % is missing from catalog',unit_row.key; end if;
      end if;
    end loop;
    for source_row in select (item->>'province_id')::integer province_id,item->>'estate' estate,
      (item->>'quantity')::integer quantity from jsonb_array_elements(plan_value->'sources') item loop
      insert into fauxlore.militia_sources(state_id,province_id,estate,quantity)
        values(militia_row.state_id,source_row.province_id,source_row.estate,source_row.quantity);
      update fauxlore.provinces set population=population-source_row.quantity
        where id=source_row.province_id and population>=source_row.quantity;
      if not found then raise exception 'Province population changed during militia call'; end if;
    end loop;
    perform fauxlore.ensure_state_group_politics(militia_row.state_id);
    update fauxlore.militia_calls set status='active',formation_id=formation_key,
      doctrine=plan_value->>'doctrine',plan=plan_value,
      loyalty_targets=case when plan_value->>'doctrine' in ('Гвардия','Кондотьеры') then
        coalesce((select jsonb_object_agg(group_key,loyalty) from fauxlore.state_group_politics
          where state_id=militia_row.state_id and group_type='estate' and status in ('Ключевое','Значимое')),'{}'::jsonb)
        else '{}'::jsonb end,
      loyalty_debt='{}'::jsonb,updated_at=now() where state_id=militia_row.state_id;
    insert into fauxlore.notifications(account_id,kind,title,message)
      select account_id,'military','Ополчение созвано','Ополчение появилось в разделе «Армии и флот».'
      from fauxlore.account_states where state_id=militia_row.state_id;
  end loop;
  for militia_row in select * from fauxlore.militia_calls where status in ('active','disbanded') order by state_id loop
    for loyalty_entry in select key,value from jsonb_each_text(militia_row.loyalty_targets) loop
      select loyalty into current_loyalty from fauxlore.state_group_politics
        where state_id=militia_row.state_id and group_type='estate' and group_key=loyalty_entry.key for update;
      if current_loyalty is null then continue; end if;
      if militia_row.status='active' then
        restoration:=least(.02,current_loyalty);
        update fauxlore.state_group_politics set loyalty=loyalty-restoration
          where state_id=militia_row.state_id and group_type='estate' and group_key=loyalty_entry.key;
        update fauxlore.militia_calls set loyalty_debt=jsonb_set(loyalty_debt,array[loyalty_entry.key],
          to_jsonb(coalesce((loyalty_debt->>loyalty_entry.key)::numeric,0)+restoration))
          where state_id=militia_row.state_id;
      else
        remaining:=coalesce((militia_row.loyalty_debt->>loyalty_entry.key)::numeric,0);
        baseline:=loyalty_entry.value::numeric;
        restoration:=greatest(0,least(.01,remaining,baseline-current_loyalty));
        if restoration>0 then
          update fauxlore.state_group_politics set loyalty=loyalty+restoration
            where state_id=militia_row.state_id and group_type='estate' and group_key=loyalty_entry.key;
          update fauxlore.militia_calls set loyalty_debt=jsonb_set(loyalty_debt,array[loyalty_entry.key],to_jsonb(remaining-restoration))
            where state_id=militia_row.state_id;
        end if;
      end if;
    end loop;
  end loop;
  return new;
end $function$;
revoke all on function fauxlore.advance_militia_turn() from public,anon,authenticated;
create trigger zz_militia_turn after update of year,turn on fauxlore.game_calendar
  for each row execute function fauxlore.advance_militia_turn();
