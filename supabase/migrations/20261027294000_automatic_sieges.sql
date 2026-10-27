-- Persist automatic sieges and resolve four deterministic-in-record seasonal phases per annual turn.
create table if not exists fauxlore.military_sieges (
  id bigint generated always as identity primary key,
  province_id integer not null references fauxlore.provinces(id),
  attacker_state_id integer not null references fauxlore.state_profiles(state_id),
  defender_state_id integer not null references fauxlore.state_profiles(state_id),
  status text not null default 'active' check(status in ('active','capitulated','lifted')),
  progress smallint not null default 0 check(progress between 0 and 100),
  breached boolean not null default false,
  previous_event_bonus smallint not null default 0 check(previous_event_bonus between -2 and 3),
  phase_log jsonb not null default '[]'::jsonb check(jsonb_typeof(phase_log)='array'),
  started_year integer not null,
  started_turn integer not null,
  updated_year integer not null,
  updated_turn integer not null,
  ended_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index if not exists military_one_active_siege_per_province
  on fauxlore.military_sieges(province_id) where status='active';
create index if not exists military_siege_state_status_idx
  on fauxlore.military_sieges(attacker_state_id,defender_state_id,status);
alter table fauxlore.military_sieges enable row level security;
revoke all on fauxlore.military_sieges from public,anon,authenticated;

create or replace function fauxlore.resolve_military_sieges(year_value integer,turn_value integer)
returns integer language plpgsql security definer set search_path='' as $function$
declare s record; siege_key bigint; attacker_power numeric; defender_power numeric; artillery_power numeric;
  engineer_attack integer; engineer_defense integer; blockade_bonus integer; fort_level integer;
  roll_value integer; phase_gain integer; phase_bonus integer; progress_value integer; breach_chance integer;
  breached_value boolean; phase_rows jsonb; phase_value jsonb; phase_number integer; loss_count integer; defender_people integer;
  attacker_name text; owner_id integer; created_count integer:=0; ratio numeric;
begin
  -- A siege is lifted when no field force of the besieging state remains in the province.
  update fauxlore.military_sieges s set status='lifted',ended_at=now(),updated_year=year_value,updated_turn=turn_value
  where s.status='active' and not exists(
    select 1 from fauxlore.military_formations f where f.active and f.transported_by is null
      and f.domain='land' and f.province_id=s.province_id and f.state_id=s.attacker_state_id);

  -- Start sieges only at enemy forts, fortresses or walled settlements and only at the approved 1.5:1 power ratio.
  for s in
    select g.province_id,g.state_id defender_state_id,attacker.state_id attacker_state_id,
      sum(au.quantity*uc.power)::numeric attacker_power,
      sum(gu.quantity*gc.power)::numeric defender_power,
      g.fort_level,g.wall_level
    from fauxlore.garrison_sites g
    join fauxlore.garrison_units gu on gu.province_id=g.province_id
    join fauxlore.military_unit_catalog gc on gc.id=gu.unit_id
    join fauxlore.military_formations attacker on attacker.active and attacker.transported_by is null
      and attacker.domain='land' and attacker.province_id=g.province_id and attacker.state_id<>g.state_id
    join fauxlore.military_wars w on w.active and
      ((w.attacker_id=attacker.state_id and w.defender_id=g.state_id) or
       (w.defender_id=attacker.state_id and w.attacker_id=g.state_id))
    join fauxlore.military_formation_units au on au.formation_id=attacker.id
    join fauxlore.military_unit_catalog uc on uc.id=au.unit_id and uc.domain in ('land','siege')
    where g.fort_level>0 or g.wall_level>0
    group by g.province_id,g.state_id,attacker.state_id,g.fort_level,g.wall_level
    having sum(au.quantity*uc.power)>=1.5*sum(gu.quantity*gc.power)
    order by g.province_id,attacker.state_id
  loop
    insert into fauxlore.military_sieges(province_id,attacker_state_id,defender_state_id,
      started_year,started_turn,updated_year,updated_turn)
    values(s.province_id,s.attacker_state_id,s.defender_state_id,year_value,turn_value,year_value,turn_value)
    on conflict(province_id) where status='active' do nothing;
    if found then
      created_count:=created_count+1;
      delete from fauxlore.military_movement_orders mo using fauxlore.military_formations f
        where f.id=mo.formation_id and f.state_id=s.attacker_state_id and f.province_id=s.province_id
          and f.active and f.domain='land';
      insert into fauxlore.notifications(account_id,kind,title,message)
      select distinct ast.account_id,'military_siege','Началась осада',
        format('В провинции «%s» началась осада. Гарнизон укрылся в укреплении.',p.name)
      from fauxlore.account_states ast cross join fauxlore.provinces p
      where p.id=s.province_id and ast.layer='states' and ast.state_id in (s.attacker_state_id,s.defender_state_id);
    end if;
  end loop;

  for s in select ms.*,g.fort_level,g.wall_level from fauxlore.military_sieges ms
    join fauxlore.garrison_sites g on g.province_id=ms.province_id
    where ms.status='active' and (ms.updated_year,ms.updated_turn)<=(year_value,turn_value)
    order by ms.province_id for update of ms
  loop
    select coalesce(sum(fu.quantity*u.power),0),
      coalesce(max((l.skills->>'Инженерные познания')::integer),0),
      coalesce(sum(fu.quantity*u.power) filter(where u.domain='siege'),0)
    into attacker_power,engineer_attack,artillery_power
    from fauxlore.military_formations f
    join fauxlore.military_formation_units fu on fu.formation_id=f.id
    join fauxlore.military_unit_catalog u on u.id=fu.unit_id and u.domain in ('land','siege')
    left join fauxlore.military_leaders l on l.id=f.leader_id and l.status='active'
    where f.active and f.transported_by is null and f.domain='land'
      and f.state_id=s.attacker_state_id and f.province_id=s.province_id;
    select coalesce(sum(gu.quantity*u.power),0) into defender_power
      from fauxlore.garrison_units gu join fauxlore.military_unit_catalog u on u.id=gu.unit_id
      where gu.province_id=s.province_id;
    if attacker_power<1.5*defender_power or defender_power<=0 then
      update fauxlore.military_sieges set updated_year=year_value,updated_turn=turn_value where id=s.id;
      continue;
    end if;

    -- Garrison sites do not yet have an assigned commander; their engineering skill is zero.
    engineer_defense:=0;
    select coalesce(max((l.skills->>'Блокада')::integer),0) into blockade_bonus
      from fauxlore.military_formations fleet
      join fauxlore.military_leaders l on l.id=fleet.leader_id and l.status='active'
      join fauxlore.map_adjacency a on a.singleton
      cross join lateral jsonb_array_elements_text(coalesce(a.neighbors->s.province_id::text,'[]'::jsonb)) n(value)
      join fauxlore.provinces sea on sea.id=n.value::integer and sea.kind='sea'
      where fleet.active and fleet.transported_by is null and fleet.domain='naval'
        and fleet.state_id=s.attacker_state_id and fleet.province_id=sea.id;

    fort_level:=s.fort_level+s.wall_level;
    ratio:=attacker_power/nullif(defender_power,0);
    breach_chance:=case when artillery_power/defender_power>=4 then 100
      when artillery_power/defender_power>=3 then 70 when artillery_power/defender_power>=2 then 35 else 0 end;
    progress_value:=s.progress;
    breached_value:=s.breached;
    phase_bonus:=s.previous_event_bonus;
    phase_rows:='[]'::jsonb;
    for phase_number in 1..4 loop
      select coalesce(sum(gu.quantity*u.power),0) into defender_power
        from fauxlore.garrison_units gu join fauxlore.military_unit_catalog u on u.id=gu.unit_id
        where gu.province_id=s.province_id;
      if defender_power<=0 then progress_value:=100; exit; end if;
      ratio:=attacker_power/defender_power;
      roll_value:=floor(random()*10)::integer+1;
      phase_gain:=greatest(0,roll_value+engineer_attack-engineer_defense+blockade_bonus
        +floor(ratio)::integer-fort_level+phase_bonus);
      progress_value:=least(100,progress_value+phase_gain);
      select coalesce(sum(quantity),0)::integer into defender_people
        from fauxlore.garrison_units where province_id=s.province_id;
      loss_count:=case when phase_gain>0 then ceil(defender_people*phase_gain/100.0)::integer else 0 end;
      loss_count:=fauxlore.apply_siege_garrison_losses(s.province_id,loss_count);
      if not breached_value and breach_chance>0 and random()*100<breach_chance then breached_value:=true; end if;
      -- Event band is intentionally small and recorded, so the next seasonal phase can reproduce the bonus.
      phase_bonus:=case when phase_gain>=12 then 2 when phase_gain>=7 then 1 when phase_gain=0 then -1 else 0 end;
      phase_value:=jsonb_build_object('season_phase',phase_number,'d10',roll_value,
        'engineering_difference',engineer_attack-engineer_defense,'naval_blockade_bonus',blockade_bonus,
        'power_ratio',round(ratio,2),'power_ratio_bonus',floor(ratio)::integer,'fortification_level',fort_level,
        'previous_event_bonus',s.previous_event_bonus,'progress_gain',phase_gain,'progress_total',progress_value,
        'event_bonus_next_phase',phase_bonus,'breach_chance_pct',breach_chance,'breached',breached_value,
        'garrison_losses',loss_count);
      phase_rows:=phase_rows||jsonb_build_array(phase_value);
      if progress_value>=100 then exit; end if;
      s.previous_event_bonus:=phase_bonus;
    end loop;

    update fauxlore.military_sieges set progress=progress_value,breached=breached_value,
      previous_event_bonus=phase_bonus,phase_log=phase_log||phase_rows,
      updated_year=year_value,updated_turn=turn_value,
      status=case when progress_value>=100 then 'capitulated' else 'active' end,
      ended_at=case when progress_value>=100 then now() else null end
      where id=s.id;
    if progress_value>=100 then
      select name into attacker_name from fauxlore.map_categories where layer='states' and id=s.attacker_state_id;
      select category_id into owner_id from fauxlore.province_values where province_id=s.province_id and layer='states';
      delete from fauxlore.garrison_units where province_id=s.province_id;
      update fauxlore.garrison_sites set state_id=s.attacker_state_id where province_id=s.province_id;
      update fauxlore.provinces set occupation=case when owner_id=s.attacker_state_id then null else attacker_name end,control=100
        where id=s.province_id;
      insert into fauxlore.notifications(account_id,kind,title,message)
      select distinct ast.account_id,'military_siege','Укрепление капитулировало',
        format('Гарнизон провинции «%s» капитулировал после осады. Контроль и укрепление перешли государству «%s».',p.name,attacker_name)
      from fauxlore.account_states ast cross join fauxlore.provinces p
      where p.id=s.province_id and ast.layer='states' and ast.state_id in (s.attacker_state_id,s.defender_state_id);
    end if;
  end loop;
  return created_count;
end
$function$;
revoke all on function fauxlore.resolve_military_sieges(integer,integer) from public,anon,authenticated;

create or replace function fauxlore.apply_siege_garrison_losses(province_key integer,loss_count integer)
returns integer language plpgsql security definer set search_path='' as $function$
declare item record; applied integer:=0; total_value integer; target_value integer;
begin
  select coalesce(sum(quantity),0)::integer into total_value from fauxlore.garrison_units where province_id=province_key;
  target_value:=least(greatest(0,loss_count),total_value);
  if target_value=0 or total_value=0 then return 0; end if;
  for item in
    with raw as (
      select unit_id,quantity,target_value::numeric*quantity/total_value exact_loss
      from fauxlore.garrison_units where province_id=province_key
    ), base as (
      select unit_id,quantity,floor(exact_loss)::integer base_loss,exact_loss-floor(exact_loss) remainder
      from raw
    ), ranked as (
      select *,sum(base_loss) over() base_total,
        row_number() over(order by remainder desc,unit_id) fraction_rank
      from base
    )
    select unit_id,least(quantity,base_loss+case when fraction_rank<=target_value-base_total then 1 else 0 end)::integer losses
    from ranked order by unit_id
  loop
    if item.losses>=item.quantity then
      delete from fauxlore.garrison_units where province_id=province_key and unit_id=item.unit_id;
      applied:=applied+item.quantity;
    elsif item.losses>0 then
      update fauxlore.garrison_units set quantity=quantity-item.losses
        where province_id=province_key and unit_id=item.unit_id;
      applied:=applied+item.losses;
    end if;
  end loop;
  return applied;
end
$function$;
revoke all on function fauxlore.apply_siege_garrison_losses(integer,integer) from public,anon,authenticated;

create or replace function public.military_siege_api(target_state integer default null)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; states integer[]; result jsonb;
begin
  actor:=fauxlore.current_account();
  select coalesce(array_agg(ast.state_id),'{}'::integer[]) into states
    from fauxlore.account_states ast where ast.account_id=actor.id and ast.layer='states';
  if actor.role<>'admin' and (target_state is null or not target_state=any(states)) then
    raise sqlstate '42501' using message='Нет доступа к осадам этого государства';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'province_id',s.province_id,'province_name',p.name,
    'attacker_state_id',s.attacker_state_id,'attacker_name',attacker.name,'defender_state_id',s.defender_state_id,
    'defender_name',defender.name,'status',s.status,'progress',s.progress,'breached',s.breached,
    'started_year',s.started_year,'started_turn',s.started_turn,'updated_year',s.updated_year,'updated_turn',s.updated_turn,
    'phase_log',s.phase_log,'fort_level',g.fort_level,'wall_level',g.wall_level)
    order by s.status='active' desc,s.updated_year desc,s.updated_turn desc,s.id desc),'[]'::jsonb)
  into result from fauxlore.military_sieges s
  join fauxlore.provinces p on p.id=s.province_id
  join fauxlore.map_categories attacker on attacker.layer='states' and attacker.id=s.attacker_state_id
  join fauxlore.map_categories defender on defender.layer='states' and defender.id=s.defender_state_id
  join fauxlore.garrison_sites g on g.province_id=s.province_id
  where actor.role='admin' or s.attacker_state_id=any(states) or s.defender_state_id=any(states);
  return jsonb_build_object('sieges',result);
end
$function$;
revoke all on function public.military_siege_api(integer) from public,anon;
grant execute on function public.military_siege_api(integer) to authenticated;

-- Resolve sieges after movement and attrition, before regular battle detection.
do $migration$
declare fn text; marker text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.turn_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  marker:='  perform fauxlore.resolve_military_encounters(calendar_row.year,calendar_row.turn);';
  if position(marker in fn)=0 then raise exception 'Could not insert sieges into the annual turn sequence'; end if;
  fn:=replace(fn,marker,'  perform fauxlore.resolve_military_sieges(calendar_row.year,calendar_row.turn);'||chr(10)||marker);
  execute fn;
end
$migration$;

select pg_notify('pgrst','reload schema');
