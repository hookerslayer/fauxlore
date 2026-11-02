insert into fauxlore.permanent_modifier_definitions(source_kind,source_key,modifier_key,effect,value,unit,scope,condition_text) values
 ('constructor','Назначение','infantry_hire_cost','Стоимость пехоты',0,'%','Государство',''),
 ('constructor','Назначение','siege_hire_cost','Стоимость осадных орудий',0,'%','Государство',''),
 ('constructor','Назначение','artillery_hire_cost','Стоимость артиллерии',0,'%','Государство',''),
 ('constructor','Назначение','infantry_upkeep','Содержание пехоты',0,'%','Государство',''),
 ('constructor','Назначение','siege_upkeep','Содержание осадных орудий',0,'%','Государство',''),
 ('constructor','Назначение','artillery_upkeep','Содержание артиллерии',0,'%','Государство','');
do $migration$
declare fn text; marker text; replacement text;
begin
 fn:=pg_get_functiondef('fauxlore.military_unit_cost_factor(integer,bigint,text)'::regprocedure);
 marker:=$old$      case when u.category='Кавалерия' then 'cavalry_hire_cost' end,$old$;
 replacement:=$new$      case when u.category='Пехота' then 'infantry_hire_cost' end,
      case when u.category='Осада' then 'siege_hire_cost' end,
      case when u.category='Артиллерия' then 'artillery_hire_cost' end,
      case when u.category='Кавалерия' then 'cavalry_hire_cost' end,$new$;
 if position(marker in fn)=0 then raise exception 'unit hire factor hook missing'; end if;fn:=replace(fn,marker,replacement);
 marker:=$old$      case when u.category='Кавалерия' then 'cavalry_upkeep' end,$old$;
 replacement:=$new$      case when u.category='Пехота' then 'infantry_upkeep' end,
      case when u.category='Осада' then 'siege_upkeep' end,
      case when u.category='Артиллерия' then 'artillery_upkeep' end,
      case when u.category='Кавалерия' then 'cavalry_upkeep' end,$new$;
 if position(marker in fn)=0 then raise exception 'unit upkeep factor hook missing'; end if; execute replace(fn,marker,replacement);
end $migration$;
notify pgrst,'reload schema';
