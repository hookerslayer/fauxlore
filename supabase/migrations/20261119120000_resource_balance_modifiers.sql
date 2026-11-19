-- Resource surplus/deficit modifiers.
-- A state's resource balance is the fulfilled flow of the last computed turn:
-- production - consumption + contract imports + zone imports - exports.
-- Balance <= -100 is a deficit, balance >= 500 is a surplus. The matching
-- effects are exposed as permanent modifiers, so every existing calculation
-- (loyalty, production, development limit, crime, hire/construction costs,
-- trade influence, movement and trade-route limits, prestige income) picks
-- them up through fauxlore.state_permanent_modifier_total.

create table if not exists fauxlore.resource_balance_effects(
  resource_name text not null,
  status text not null check(status in ('deficit','surplus')),
  modifier_key text not null,
  value numeric not null,
  unit text not null,
  scope text not null default 'Государство',
  effect text not null,
  sort_order integer not null default 0,
  exclude_religion text,
  primary key(resource_name,status,modifier_key,scope)
);
alter table fauxlore.resource_balance_effects enable row level security;
revoke all on fauxlore.resource_balance_effects from public,anon,authenticated;

insert into fauxlore.resource_balance_effects
  (resource_name,status,modifier_key,value,unit,scope,effect,sort_order,exclude_religion)
values
  ('Зерно','deficit','estate_loyalty',-.05,'п.п.','Государство','Лояльность всех сословий',1,null),
  ('Зерно','deficit','population_growth',-.005,'%','Государство','Прирост населения',2,null),
  ('Зерно','deficit','development_limit_flat',-100,'ур.','Государство','Лимит развития',3,null),

  ('Лес','deficit','construction_cost',1.0,'%','Государство','Стоимость строительства крепостей, портов и городских стен',1,null),
  ('Лес','deficit','fleet_hire_cost',2.0,'%','Государство','Стоимость закладки флота',2,null),
  ('Лес','deficit','development_limit_flat',-300,'ур.','Государство','Лимит развития',3,null),

  ('Морепродукты','deficit','estate_loyalty',-.05,'п.п.','Государство','Лояльность всех сословий',1,null),
  ('Морепродукты','deficit','development_limit_flat',-50,'ур.','Государство','Лимит развития',2,null),

  ('Животноводство','deficit','estate_loyalty',-.05,'п.п.','Государство','Лояльность всех сословий',1,null),
  ('Животноводство','deficit','production',-.10,'п.п.','Государство','Производство в провинциях',2,null),
  ('Животноводство','deficit','crime_pp',.05,'п.п.','Государство','Преступность',3,null),
  ('Животноводство','deficit','development_limit_flat',-50,'ур.','Государство','Лимит развития',4,null),

  ('Соль','deficit','burgher_loyalty',-.05,'п.п.','Государство','Лояльность Горожан',1,null),
  ('Соль','deficit','trade_influence',-.20,'п.п.','Государство','Торговое влияние',2,null),
  ('Соль','deficit','development_limit_flat',-50,'ур.','Государство','Лимит развития',3,null),
  ('Соль','surplus','trade_influence',.20,'п.п.','Государство','Торговое влияние',1,null),
  ('Соль','surplus','land_trade_range',5,'провинции','Государство','Лимит провинций торгового маршрута (сухопутный)',2,null),
  ('Соль','surplus','sea_trade_range',5,'провинции','Государство','Лимит провинций торгового маршрута (морской)',3,null),
  ('Соль','surplus','army_movement_limit',3,'провинции','Государство','Лимит передвижения армии',4,null),
  ('Соль','surplus','fleet_movement_limit',3,'провинции','Государство','Лимит передвижения флота',5,null),

  ('Хлопок','deficit','estate_loyalty',-.05,'п.п.','Государство','Лояльность всех сословий',1,null),
  ('Хлопок','deficit','fleet_hire_cost',.5,'%','Государство','Стоимость закладки флота',2,null),
  ('Хлопок','deficit','development_limit_flat',-50,'ур.','Государство','Лимит развития',3,null),

  ('Металлы','deficit','burgher_loyalty',-.05,'п.п.','Государство','Лояльность Горожан',1,null),
  ('Металлы','deficit','production',-.30,'п.п.','Государство','Производство в провинциях',2,null),
  ('Металлы','deficit','regular_hire_cost',2.0,'%','Государство','Стоимость найма регулярной армии',3,null),
  ('Металлы','deficit','fleet_hire_cost',2.0,'%','Государство','Стоимость закладки флота',4,null),
  ('Металлы','deficit','garrison_hire_cost',1.0,'%','Государство','Стоимость найма в гарнизон',5,null),
  ('Металлы','deficit','construction_cost',.5,'%','Государство','Стоимость строительства крепостей, портов и городских стен',6,null),
  ('Металлы','deficit','colonization_cost',.2,'%','Государство','Стоимость колонизации',7,null),
  ('Металлы','deficit','militia_coefficient',-.3,'коэфф.','Государство','Коэффициент сбора ополчения',8,null),
  ('Металлы','deficit','development_limit_flat',-50,'ур.','Государство','Лимит развития',9,null),

  ('Мех','deficit','key_estate_loyalty',-.05,'п.п.','Государство','Лояльность ключевых сословий',1,null),
  ('Мех','deficit','development_limit_flat',-50,'ур.','Государство','Лимит развития',2,null),
  ('Мех','surplus','trade_influence',.10,'п.п.','Государство','Торговое влияние',1,null),
  ('Мех','surplus','development_limit_flat',100,'ур.','Государство','Лимит развития',2,null),

  ('Красители','deficit','key_estate_loyalty',-.05,'п.п.','Государство','Лояльность ключевых сословий',1,null),
  ('Красители','deficit','burgher_loyalty',-.05,'п.п.','Государство','Лояльность Горожан',2,null),
  ('Красители','deficit','development_limit_flat',-50,'ур.','Государство','Лимит развития',3,null),
  ('Красители','surplus','trade_influence',.20,'п.п.','Государство','Торговое влияние',1,null),
  ('Красители','surplus','development_limit_flat',100,'ур.','Государство','Лимит развития',2,null),

  ('Табак','surplus','clergy_loyalty',.03,'п.п.','Государство','Лояльность Духовенства',1,null),
  ('Табак','surplus','prestige',1,'ОП/ход','Государство','Престиж за ход',2,null),
  ('Табак','surplus','development_limit_flat',100,'ур.','Государство','Лимит развития',3,null),

  ('Селитра','deficit','firearms_hire_cost',2.0,'%','Государство','Стоимость найма пищальников и артиллерии',1,null),
  ('Селитра','surplus','production',.20,'п.п.','Ресурс:Зерно','Производство зерна',1,null),
  ('Селитра','surplus','production',.20,'п.п.','Ресурс:Хлопок','Производство хлопка',2,null),
  ('Селитра','surplus','production',.20,'п.п.','Ресурс:Фрукты','Производство фруктов',3,null),
  ('Селитра','surplus','production',.20,'п.п.','Ресурс:Чай','Производство чая',4,null),
  ('Селитра','surplus','production',.20,'п.п.','Ресурс:Табак','Производство табака',5,null),
  ('Селитра','surplus','production',.20,'п.п.','Ресурс:Сахар','Производство сахара',6,null),
  ('Селитра','surplus','production',.20,'п.п.','Ресурс:Кофе','Производство кофе',7,null),
  ('Селитра','surplus','production',.20,'п.п.','Ресурс:Эфемера','Производство эфемеры',8,null),

  ('Фрукты','surplus','development_limit_flat',100,'ур.','Государство','Лимит развития',1,null),
  ('Сахар','surplus','development_limit_flat',100,'ур.','Государство','Лимит развития',1,null),
  ('Чай','surplus','development_limit_flat',100,'ур.','Государство','Лимит развития',1,null),
  ('Кофе','surplus','development_limit_flat',100,'ур.','Государство','Лимит развития',1,null),

  ('Шёлк','deficit','nobility_loyalty',-.05,'п.п.','Государство','Лояльность Знати',1,null),
  ('Шёлк','surplus','development_limit_flat',100,'ур.','Государство','Лимит развития',1,null),

  ('Жемчуг','deficit','clergy_loyalty',-.05,'п.п.','Государство','Лояльность Духовенства',1,null),
  ('Жемчуг','deficit','development_limit_flat',-50,'ур.','Государство','Лимит развития',2,null),
  ('Жемчуг','surplus','development_limit_flat',100,'ур.','Государство','Лимит развития',1,null),

  ('Драгоценные металлы','deficit','key_estate_loyalty',-.10,'п.п.','Государство','Лояльность ключевых сословий',1,'Стратерианство'),
  ('Драгоценные металлы','deficit','corruption_pp',.05,'п.п.','Государство','Коррупция',2,'Стратерианство'),
  ('Драгоценные металлы','deficit','crime_pp',.05,'п.п.','Государство','Преступность',3,'Стратерианство'),
  ('Драгоценные металлы','surplus','development_limit_flat',300,'ур.','Государство','Лимит развития',1,null),

  ('Эфемера','deficit','clergy_loyalty',-.10,'п.п.','Государство','Лояльность Духовенства',1,'Правоверие'),
  ('Эфемера','deficit','development_limit_flat',-200,'ур.','Государство','Лимит развития',2,'Правоверие'),
  ('Эфемера','surplus','development_limit_flat',300,'ур.','Государство','Лимит развития',1,null)
on conflict(resource_name,status,modifier_key,scope) do update
  set value=excluded.value, unit=excluded.unit, effect=excluded.effect,
      sort_order=excluded.sort_order, exclude_religion=excluded.exclude_religion;

create or replace function fauxlore.state_resource_balances(target_state integer)
returns table(resource_name text, amount numeric, status text)
language sql stable security definer set search_path='' as $fn$
  with latest as (
    select r.year,r.turn from fauxlore.trade_state_resource_turns r
    order by r.year desc,r.turn desc limit 1
  )
  select r.resource_name,
    (r.production-r.consumption+r.contract_import+r.zone_import-r.contract_export-r.zone_export)::numeric,
    case
      when (r.production-r.consumption+r.contract_import+r.zone_import-r.contract_export-r.zone_export)<=-100 then 'deficit'
      when (r.production-r.consumption+r.contract_import+r.zone_import-r.contract_export-r.zone_export)>=500 then 'surplus'
      else 'normal' end
  from fauxlore.trade_state_resource_turns r
  join latest l on l.year=r.year and l.turn=r.turn
  where r.state_id=target_state
$fn$;
revoke all on function fauxlore.state_resource_balances(integer) from public,anon,authenticated;

create or replace function fauxlore.state_resource_modifier_rows(target_state integer)
returns jsonb language sql stable security definer set search_path='' as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
    'source_kind','resource','source',b.resource_name,'key',e.modifier_key,'effect',e.effect,
    'value',e.value,'unit',e.unit,'scope',e.scope,'condition','','status','Активен',
    'duration',case b.status when 'deficit' then 'Пока дефицит' else 'Пока профицит' end,
    'target_province_id',null::integer,'target_trade_zone_id',null::integer)
    order by b.resource_name,e.sort_order),'[]'::jsonb)
  from fauxlore.state_resource_balances(target_state) b
  join fauxlore.resource_balance_effects e on e.resource_name=b.resource_name and e.status=b.status
  left join fauxlore.state_profiles sp on sp.state_id=target_state
  left join fauxlore.map_categories rel on rel.layer='religions' and rel.id=sp.official_religion_id
  where e.exclude_religion is null or coalesce(rel.name,'')<>e.exclude_religion
$fn$;
revoke all on function fauxlore.state_resource_modifier_rows(integer) from public,anon,authenticated;

-- Keep the original catalogue intact and expose it under a stable name, so the
-- resource rows are appended in one place instead of editing a large query.
do $migration$
declare definition text;
begin
  definition:=pg_get_functiondef('fauxlore.state_permanent_modifiers(integer)'::regprocedure);
  if position('state_permanent_modifiers_base' in definition)=0 then
    definition:=replace(definition,'FUNCTION fauxlore.state_permanent_modifiers(',
      'FUNCTION fauxlore.state_permanent_modifiers_base(');
    execute definition;
  end if;
end $migration$;
revoke all on function fauxlore.state_permanent_modifiers_base(integer) from public,anon,authenticated;

create or replace function fauxlore.state_permanent_modifiers(target_state integer)
returns jsonb language sql stable security definer set search_path='' as $fn$
  select coalesce(jsonb_agg(value order by ord),'[]'::jsonb)
  from (
    select value,ord from jsonb_array_elements(fauxlore.state_permanent_modifiers_base(target_state))
      with ordinality as t(value,ord)
    union all
    select value,1000+ord from jsonb_array_elements(fauxlore.state_resource_modifier_rows(target_state))
      with ordinality as t(value,ord)
  ) rows
$fn$;
revoke all on function fauxlore.state_permanent_modifiers(integer) from public,anon,authenticated;

-- Resource-scoped entries act only on the province resource they name.
do $migration$
declare definition text; marker text;
begin
  definition:=pg_get_functiondef('fauxlore.state_permanent_modifier_total(integer,text[],integer,text)'::regprocedure);
  if position('scope_value like ''Ресурс:%''' in definition)=0 then
    marker:=$m$    if row_value->>'key'='precious_consumption'$m$;
    if position(marker in definition)=0 then raise exception 'Modifier resource check changed'; end if;
    definition:=replace(definition,marker,
      $m$    if scope_value like 'Ресурс:%' and target_resource is distinct from substring(scope_value from length('Ресурс:')+1) then continue; end if;$m$||chr(10)||marker);
    marker:=$m$if scope_value like 'Провинции %' or scope_value like '% + %' or scope_value in ('Регионы','Городские и Столичная') then continue; end if;$m$;
    if position(marker in definition)=0 then raise exception 'Modifier scope filter changed'; end if;
    definition:=replace(definition,marker,
      $m$if scope_value like 'Провинции %' or scope_value like '% + %' or scope_value like 'Ресурс:%' or scope_value in ('Регионы','Городские и Столичная') then continue; end if;$m$);
    execute definition;
  end if;
end $migration$;

-- Loyalty of the estates that hold the key political status.
do $migration$
declare definition text; marker text;
begin
  definition:=pg_get_functiondef('fauxlore.effective_estate_loyalties(integer)'::regprocedure);
  if position('key_estate_loyalty' in definition)=0 then
    marker:=$m$+fauxlore.state_permanent_modifier_total(target_state,array['estate_loyalty'],null,null)$m$;
    if position(marker in definition)=0 then raise exception 'Estate loyalty modifier hook changed'; end if;
    definition:=replace(definition,marker,marker||
      $m$+case when status='Ключевое' then fauxlore.state_permanent_modifier_total(target_state,array['key_estate_loyalty'],null,null) else 0 end$m$);
    execute definition;
  end if;
end $migration$;

-- Construction of forts, walls and ports.
do $migration$
declare definition text; marker text:=$m$cost_value:=floor(cost_value*fauxlore.state_cost_multiplier(sid));$m$;
  replacement text:=$m$cost_value:=floor(cost_value*greatest(0,1+fauxlore.state_permanent_modifier_total(sid,array['construction_cost'],null,null)));$m$||chr(10)||
    $m$  cost_value:=floor(cost_value*fauxlore.state_cost_multiplier(sid));$m$;
begin
  definition:=pg_get_functiondef('public.garrison_api(text,integer,integer,jsonb)'::regprocedure);
  if position('construction_cost' in definition)=0 then
    if position(marker in definition)=0 then raise exception 'Garrison construction cost hook changed'; end if;
    execute replace(definition,marker,replacement);
  end if;
  definition:=pg_get_functiondef('fauxlore.military_start_port_construction(integer,jsonb)'::regprocedure);
  if position('construction_cost' in definition)=0 then
    marker:=$m$cost_value:=floor(10000*fauxlore.state_cost_multiplier(sid));$m$;
    if position(marker in definition)=0 then raise exception 'Port construction cost hook changed'; end if;
    execute replace(definition,$m$cost_value:=floor(10000*fauxlore.state_cost_multiplier(sid));$m$,
      $m$cost_value:=floor(10000*greatest(0,1+fauxlore.state_permanent_modifier_total(sid,array['construction_cost'],null,null))*fauxlore.state_cost_multiplier(sid));$m$);
  end if;
end $migration$;

-- Colonization price follows the resource price modifiers.
do $migration$
declare definition text; marker text:=$m$gold_base:=case when sea_value then 2400 else 1200 end;$m$;
  replacement text:=$m$gold_base:=floor((case when sea_value then 2400 else 1200 end)*greatest(0,1+fauxlore.state_permanent_modifier_total(state_key,array['colonization_cost'],null,null)));$m$;
begin
  definition:=pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure);
  if position('colonization_cost' in definition)=0 then
    if position(marker in definition)=0 then raise exception 'Colonization cost hook changed'; end if;
    execute replace(definition,marker,replacement);
  end if;
end $migration$;

notify pgrst,'reload schema';
