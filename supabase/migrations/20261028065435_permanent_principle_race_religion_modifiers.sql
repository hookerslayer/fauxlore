-- Data registry for automatically active modifiers from principles, races and
-- religions. It is private and exposed only through the state indicator API.
create table if not exists fauxlore.permanent_modifier_definitions (
  source_kind text not null check (source_kind in ('authority','structure','economy','military','race','religion')),
  source_key text not null,
  modifier_key text not null,
  effect text not null,
  value numeric not null,
  unit text not null,
  scope text not null,
  condition_text text not null default '',
  primary key(source_kind,source_key,modifier_key)
);
alter table fauxlore.permanent_modifier_definitions enable row level security;
revoke all on fauxlore.permanent_modifier_definitions from public,anon,authenticated;

insert into fauxlore.permanent_modifier_definitions
  (source_kind,source_key,modifier_key,effect,value,unit,scope,condition_text) values
-- Authority
('authority','Династия','prestige','Престиж за ход',1,'ОП/ход','Государство',''),
('authority','Династия','precious_consumption','Потребление Драгоценных металлов',.10,'%','Государство',''),
('authority','Династия','regional_development','Развитие',.25,'ед./ход','Регионы','Лояльность Знати выше 60%'),
('authority','Династия','recruit_growth','Прирост рекрутов',-.10,'%','Государство',''),
('authority','Династия','recruit_limit','Лимит рекрутов',-.10,'%','Государство',''),
('authority','Магистрат','prestige','Престиж за ход',1,'ОП/ход','Государство',''),
('authority','Магистрат','urban_development','Развитие',.75,'ед./ход','Городские и Столичная','Лояльность ключевых сословий выше 60%'),
('authority','Магистрат','tax_efficiency','Эффективность налогообложения',.10,'п.п.','Городские и Столичная',''),
('authority','Магистрат','trade_influence','Торговое влияние',.15,'%','Городские и Столичная',''),
('authority','Клир','precious_consumption','Потребление Драгоценных металлов',.50,'%','Государство',''),
('authority','Клир','other_consumption','Потребление остальных ресурсов',-.10,'%','Государство',''),
('authority','Клир','estate_loyalty','Лояльность сословий',.10,'п.п.','Все сословия',''),
('authority','Клир','prestige','Престиж за ход',2,'ОП/ход','Государство',''),
('authority','Клир','recruit_growth','Прирост рекрутов',-.20,'%','Государство',''),
('authority','Клир','recruit_limit','Лимит рекрутов',-.20,'%','Государство',''),
('authority','Клир','militia_coefficient','Коэффициент созыва ополчения',.2,'коэфф.','Государство',''),
('authority','Диктат','prestige','Престиж за ход',-1,'ОП/ход','Государство',''),
('authority','Диктат','prestige_action_cost','Стоимость действий за ОП',-1,'ОП/действие','Действие','Не ниже 0 ОП'),
('authority','Диктат','tax_efficiency','Эффективность налогообложения',.10,'п.п.','Все провинции',''),
('authority','Диктат','recruit_growth','Прирост рекрутов',.20,'%','Государство',''),
('authority','Диктат','spy_growth','Рост шпионской сети',.10,'%','Государство',''),
('authority','Вече','prestige_action_cost','Стоимость действий за ОП',1,'ОП/действие','Действие',''),
('authority','Вече','prestige','Престиж за ход',1,'ОП/ход','Государство',''),
('authority','Вече','peasant_loyalty','Лояльность Крестьян',.10,'п.п.','Государство',''),
('authority','Вече','regional_recruit_growth','Прирост рекрутов',.10,'%','Регионы',''),
-- Ownership structure
('structure','Ленное право','militia_nobility','Мобилизационный потенциал ополчения',.20,'%','Знать',''),
('structure','Ленное право','army_upkeep','Содержание регулярной армии',-.10,'%','Государство',''),
('structure','Ленное право','garrison_limit','Лимит гарнизона',.10,'%','Государство',''),
('structure','Ленное право','regional_production','Производство',.10,'%','Регионы',''),
('structure','Деспотизм','tax_efficiency','Эффективность налогообложения',.10,'п.п.','Все провинции',''),
('structure','Деспотизм','garrison_limit','Лимит гарнизона',.20,'%','Государство',''),
('structure','Деспотизм','fortification_upkeep','Содержание гарнизонов и укреплений',-.10,'%','Государство',''),
('structure','Деспотизм','recruit_growth','Прирост рекрутов',.10,'%','Государство',''),
('structure','Консорциум','trade_influence','Торговое влияние',.15,'%','Государство',''),
('structure','Консорциум','trade_zone_income','Доход от торговых зон',.10,'%','Государство',''),
('structure','Консорциум','land_trade_range','Длина сухопутного маршрута',3,'провинции','Государство',''),
('structure','Консорциум','urban_production','Производство',.20,'%','Городские и Столичная',''),
('structure','Содружество','internal_trade_income','Доход от внутренней торговли',.10,'%','Государство',''),
('structure','Содружество','land_trade_range','Длина сухопутного маршрута',3,'провинции','Государство',''),
('structure','Содружество','militia_potential','Мобилизационный потенциал ополчения',.10,'%','Государство',''),
('structure','Командорство','garrison_limit','Лимит гарнизона',.20,'%','Государство',''),
('structure','Командорство','fortification_upkeep','Содержание гарнизонов и укреплений',-.15,'%','Государство',''),
('structure','Командорство','militia_clergy','Мобилизационный потенциал ополчения',.20,'%','Духовенство',''),
('structure','Командорство','recruit_growth','Прирост рекрутов',.10,'%','Государство',''),
-- Economic model
('economy','Крепостничество','nobility_loyalty','Лояльность Знати',.10,'п.п.','Государство',''),
('economy','Крепостничество','peasant_loyalty','Лояльность Крестьян',-.10,'п.п.','Государство',''),
('economy','Крепостничество','peasant_influence','Влияние Крестьян',-.10,'%','Государство',''),
('economy','Крепостничество','production','Производство',.50,'%','Все провинции',''),
('economy','Крепостничество','trade_influence','Торговое влияние',-.20,'%','Государство',''),
('economy','Гильдии','urban_development','Развитие',1,'ед./ход','Городские и Столичная',''),
('economy','Гильдии','regional_development_cap','Прирост развития',1,'ед./ход','Регионы','Максимум'),
('economy','Гильдии','urban_production','Производство',.20,'%','Городские и Столичная',''),
('economy','Гильдии','consumption','Потребление ресурсов',.10,'%','Все ресурсы',''),
('economy','Гильдии','land_trade_range','Длина сухопутного маршрута',3,'провинции','Государство',''),
('economy','Гильдии','trade_influence','Торговое влияние',.15,'%','Государство',''),
('economy','Адмиралтейство','urban_development','Развитие',1,'ед./ход','Городские и Столичная',''),
('economy','Адмиралтейство','regional_development_cap','Прирост развития',1,'ед./ход','Регионы','Максимум'),
('economy','Адмиралтейство','consumption','Потребление ресурсов',.10,'%','Все ресурсы',''),
('economy','Адмиралтейство','sea_trade_range','Длина морского маршрута',5,'провинции','Государство',''),
('economy','Адмиралтейство','ship_hire_cost','Стоимость найма кораблей',-.15,'%','Государство',''),
('economy','Адмиралтейство','ship_upkeep','Содержание кораблей',-.15,'%','Государство',''),
('economy','Адмиралтейство','trade_influence','Торговое влияние',.15,'%','Государство',''),
('economy','Адмиралтейство','militia_cog_per_development','Когги от созыва ополчения',1,'корабль/100 развития','Прибрежная провинция',''),
('economy','Корсарство','regional_development_cap','Прирост развития',2,'ед./ход','Регионы','Максимум'),
('economy','Корсарство','ship_hire_cost','Стоимость найма кораблей',-.20,'%','Государство',''),
('economy','Корсарство','ship_upkeep','Содержание кораблей',-.20,'%','Государство',''),
('economy','Корсарство','recruit_growth','Прирост рекрутов',.30,'%','Государство',''),
('economy','Корсарство','militia_cog_per_development','Когги от созыва ополчения',1,'корабль/50 развития','Прибрежная провинция',''),
('economy','Корсарство','trade_influence','Торговое влияние',-.15,'%','Государство',''),
('economy','Корсарство','production','Производство',-.20,'%','Все провинции',''),
('economy','Корсарство','prestige_contract_cost','Стоимость договора за ОП',1,'ОП/договор','Договор',''),
('economy','Работорговля','development_cap','Прирост развития',1,'ед./ход','Все провинции','Максимум'),
('economy','Работорговля','peasant_influence','Влияние Крестьян',-.20,'%','Государство',''),
('economy','Работорговля','peasant_loyalty','Лояльность Крестьян',-.10,'п.п.','Государство',''),
('economy','Работорговля','production','Производство',1,'%','Все провинции',''),
('economy','Работорговля','militia_coefficient','Коэффициент созыва ополчения',.5,'коэфф.','Государство',''),
('economy','Работорговля','recruit_growth','Прирост рекрутов',.20,'%','Государство',''),
('economy','Работорговля','recruit_limit','Лимит рекрутов',.20,'%','Государство',''),
('economy','Работорговля','prestige','Престиж за ход',-1,'ОП/ход','Государство',''),
-- Military doctrine
('military','Сословная армия','regular_hire_cost','Стоимость найма регулярной армии',5,'%','Государство',''),
('military','Кондотьеры','regular_hire_cost','Стоимость найма регулярной армии',5,'%','Государство',''),
('military','Кондотьеры','mercenary_hire_cost','Стоимость найма наёмников',-.50,'%','Государство',''),
('military','Кондотьеры','mercenary_upkeep','Содержание наёмников',-.50,'%','Государство',''),
('military','Фирд','regular_hire_cost','Стоимость найма регулярной армии',5,'%','Государство',''),
('military','Гвардия','recruit_limit','Лимит рекрутов',1,'%','Государство',''),
('military','Гвардия','recruit_growth','Прирост рекрутов',1,'%','Государство',''),
-- Race and religion effects (activated by actual population presence).
('race','Люди','fleet_hire_cost','Стоимость найма флота',-.30,'%','Государство',''),
('race','Люди','fleet_upkeep','Содержание флота',-.30,'%','Государство',''),
('race','Люди','development','Развитие',.25,'ед./ход','Провинции с Людьми',''),
('race','Люди','population_growth','Базовый прирост населения Людей',.01,'%','Люди',''),
('race','Люди','prestige','Престиж за ход',1,'ОП/ход','Государство',''),
('race','Дварфы','garrison_limit','Лимит гарнизона',.20,'%','Провинции с Дварфами',''),
('race','Дварфы','garrison_hire_cost','Стоимость найма гарнизона',-.20,'%','Провинции с Дварфами',''),
('race','Дварфы','garrison_upkeep','Содержание гарнизона',-.20,'%','Провинции с Дварфами',''),
('race','Дварфы','fleet_hire_cost','Стоимость найма флота',.50,'%','Государство',''),
('race','Дварфы','fleet_upkeep','Содержание флота',.50,'%','Государство',''),
('race','Дварфы','cavalry_hire_cost','Стоимость найма кавалерии',.50,'%','Государство',''),
('race','Дварфы','cavalry_upkeep','Содержание кавалерии',.50,'%','Государство',''),
('race','Дварфы','crossbow_hire_cost','Стоимость найма арбалетчиков',-.10,'%','Государство',''),
('race','Дварфы','crossbow_upkeep','Содержание арбалетчиков',-.10,'%','Государство',''),
('race','Дварфы','firearms_hire_cost','Стоимость найма пищальников и артиллерии',-.30,'%','Государство',''),
('race','Дварфы','firearms_upkeep','Содержание пищальников и артиллерии',-.30,'%','Государство',''),
('race','Дварфы','metal_production','Производство Металлов и Драгоценных металлов',.20,'%','Провинции с соответствующим ресурсом',''),
('race','Дварфы','metal_development','Развитие',2,'ед./ход','Дварфы + Металлы',''),
('race','Дварфы','precious_development','Развитие',5,'ед./ход','Дварфы + Драгоценные металлы',''),
('race','Дварфы','prestige','Престиж за ход',1,'ОП/ход','Государство',''),
('race','Эльфы','forest_development','Развитие',.5,'ед./ход','Эльфы + Лес',''),
('race','Эльфы','precious_consumption','Потребление Драгоценных металлов',.20,'%','Государство',''),
('race','Эльфы','archer_hire_cost','Стоимость найма лучников',-.20,'%','Государство',''),
('race','Эльфы','archer_upkeep','Содержание лучников',-.20,'%','Государство',''),
('race','Эльфы','tax_efficiency','Эффективность налогообложения',.20,'п.п.','Провинции с Эльфами',''),
('race','Эльфы','population_growth','Базовый прирост населения Эльфов',-.02,'%','Эльфы',''),
('race','Эльфы','other_race_loyalty','Лояльность других рас',-.10,'п.п.','Невмешательство / Ассимиляция / Истребление',''),
('race','Эльфы','prestige','Престиж за ход',2,'ОП/ход','Государство',''),
('race','Полуэльфы','ephemera_production','Производство Эфемеры',3,'%','Провинции с Полуэльфами',''),
('race','Полуэльфы','ephemera_development','Развитие',5,'ед./ход','Полуэльфы + Эфемера',''),
('race','Полуэльфы','development','Развитие',.1,'ед./ход','Провинции с Полуэльфами',''),
('race','Полуэльфы','forest_development','Развитие',.1,'ед./ход','Полуэльфы + Лес',''),
('race','Полуэльфы','population_growth','Базовый прирост населения Полуэльфов',-.01,'%','Полуэльфы',''),
('race','Полуэльфы','prestige','Престиж за ход',1,'ОП/ход','Государство',''),
('race','Зверолюди','cavalry_hire_cost','Стоимость найма кавалерии',-.20,'%','Государство',''),
('race','Зверолюди','cavalry_upkeep','Содержание кавалерии',-.20,'%','Государство',''),
('race','Зверолюди','ranged_hire_cost','Стоимость найма лучников, арбалетчиков, пищальников и артиллерии',.20,'%','Государство',''),
('race','Зверолюди','ranged_upkeep','Содержание лучников, арбалетчиков, пищальников и артиллерии',.20,'%','Государство',''),
('race','Зверолюди','garrison_limit','Лимит гарнизона',-.40,'%','Провинции со Зверолюдьми',''),
('race','Зверолюди','livestock_population_growth','Прирост населения',.10,'%','Зверолюди + Животноводство',''),
('race','Зверолюди','livestock_development','Развитие',1.5,'ед./ход','Зверолюди + Животноводство',''),
('race','Зверолюди','local_recruit_growth','Прирост рекрутов',1,'%','Провинции со Зверолюдьми',''),
('race','Зверолюди','local_recruit_limit','Лимит рекрутов',1,'%','Провинции со Зверолюдьми',''),
('race','Зверолюди','prestige','Престиж за ход',1,'ОП/ход','Государство',''),
('religion','Правоверие','tax_efficiency','Эффективность налогообложения',.15,'п.п.','Провинции с Правоверием',''),
('religion','Правоверие','other_religion_loyalty','Лояльность других религий',-.10,'п.п.','Невмешательство / Ассимиляция / Истребление',''),
('religion','Правоверие','prestige','Престиж за ход',1,'ОП/ход','Государство',''),
('religion','Стратерианство','trade_influence','Торговое влияние',.10,'%','Провинции со Стратерианством',''),
('religion','Стратерианство','consumption','Потребление ресурсов',-.20,'%','Государство',''),
('religion','Стратерианство','prestige','Престиж за ход',2,'ОП/ход','Государство',''),
('religion','Витализм','colonization_chance','Шанс колонизации',.10,'п.п.','Государство',''),
('religion','Витализм','colonization_duration','Срок колонизации',-1,'ход','Провинции с Витализмом',''),
('religion','Витализм','regular_hire_cost','Стоимость найма регулярной армии',.20,'%','Государство',''),
('religion','Витализм','regular_upkeep','Содержание регулярной армии',.20,'%','Государство',''),
('religion','Витализм','garrison_limit','Лимит гарнизона',-.20,'%','Государство',''),
('religion','Витализм','prestige','Престиж за ход',3,'ОП/ход','Государство',''),
('religion','Атомизм','development','Развитие',.25,'ед./ход','Провинции с Атомизмом',''),
('religion','Атомизм','colonization_chance','Шанс колонизации',-.10,'п.п.','Государство',''),
('religion','Атомизм','local_recruit_growth','Прирост рекрутов',-.20,'%','Провинции с Атомизмом',''),
('religion','Атомизм','local_recruit_limit','Лимит рекрутов',-.20,'%','Провинции с Атомизмом',''),
('religion','Атомизм','prestige','Престиж за ход',1,'ОП/ход','Государство','')
on conflict(source_kind,source_key,modifier_key) do update set
  effect=excluded.effect,value=excluded.value,unit=excluded.unit,scope=excluded.scope,condition_text=excluded.condition_text;

create or replace function fauxlore.state_permanent_modifiers(target_state integer)
returns jsonb language sql stable security definer set search_path='' as $$
with state_row as (
  select sp.principles,sp.state_id,c.name state_name
  from fauxlore.state_profiles sp join fauxlore.map_categories c on c.layer='states' and c.id=sp.state_id
  where sp.state_id=target_state
), present_groups as (
  select distinct v.layer source_kind,c.name source_key
  from fauxlore.province_values owner_value
  join fauxlore.provinces p on p.id=owner_value.province_id and p.kind='land'
  join fauxlore.province_values v on v.province_id=p.id and v.layer in ('races','religions')
  join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id
  where owner_value.layer='states' and owner_value.category_id=target_state
), active as (
  select d.*,case d.source_kind
    when 'authority' then s.principles->>'authority'
    when 'structure' then s.principles->>'structure'
    when 'economy' then s.principles->>'economy'
    when 'military' then s.principles->>'military'
    else d.source_key end active_source
  from fauxlore.permanent_modifier_definitions d cross join state_row s
  where (d.source_kind in ('authority','structure','economy','military') and
    case d.source_kind when 'authority' then s.principles->>'authority' when 'structure' then s.principles->>'structure'
      when 'economy' then s.principles->>'economy' when 'military' then s.principles->>'military' end=d.source_key)
    or (d.source_kind in ('race','religion') and exists(select 1 from present_groups g where g.source_kind=d.source_kind||'s' and g.source_key=d.source_key))
)
select coalesce(jsonb_agg(jsonb_build_object(
  'source_kind',source_kind,'source',source_key,'key',modifier_key,'effect',effect,'value',value,
  'unit',unit,'scope',scope,'condition',condition_text,'status','Активен','duration','Постоянный')
  order by case source_kind when 'authority' then 1 when 'structure' then 2 when 'economy' then 3 when 'military' then 4 when 'race' then 5 else 6 end,source_key,modifier_key), '[]'::jsonb)
from active
$$;
revoke all on function fauxlore.state_permanent_modifiers(integer) from public,anon,authenticated;

create or replace function fauxlore.state_indicators(target_state integer)
returns jsonb language sql stable security definer set search_path='' as $$
select fauxlore.state_indicators_before_urbanization(target_state)
  ||fauxlore.state_population_growth(target_state)
  ||fauxlore.state_recruitment(target_state)
  ||jsonb_build_object('corruption_loyalty_bonus',least((cfg.config#>>'{stateEffects,corruptionLoyaltyCap}')::numeric,sp.corruption/(cfg.config#>>'{stateEffects,corruptionLoyaltyDivisor}')::numeric),
    'base_tax_efficiency',fauxlore.province_tax_efficiency_base(),'state_effect_coefficients',cfg.config->'stateEffects',
    'permanent_modifiers',fauxlore.state_permanent_modifiers(target_state))
from fauxlore.economy_parameters cfg join fauxlore.state_profiles sp on sp.state_id=target_state where cfg.singleton
$$;
revoke all on function fauxlore.state_indicators(integer) from public,anon,authenticated;
grant execute on function fauxlore.state_indicators(integer) to authenticated;
notify pgrst,'reload schema';
