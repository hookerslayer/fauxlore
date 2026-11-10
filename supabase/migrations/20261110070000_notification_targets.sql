-- Метаданные для кнопки «Перейти» в уведомлениях.
-- target_provinces — провинции, на которые нужно навести камеру;
-- target_layer — слой карты, который нужно включить.
--
-- Размечаются основные типы: приказы передвижения, колонизация, завоевание,
-- строительство гарнизонов и портов.

do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to patch notifications outside production candidate';
  end if;
end
$guard$;

alter table fauxlore.notifications add column if not exists target_provinces integer[];
alter table fauxlore.notifications add column if not exists target_layer text;

-- GET notifications: отдаём новые поля.
do $patch$
declare definition text; marker text; replacement text;
begin
  select pg_get_functiondef('fauxlore.registration_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  marker := $m$'application_id',n.application_id,'created_at',n.created_at,'read',n.read_at is not null)$m$;
  if position(marker in definition) = 0 then raise exception 'GET notifications marker missing'; end if;
  replacement := $m$'application_id',n.application_id,'created_at',n.created_at,'read',n.read_at is not null,
      'target_provinces',n.target_provinces,'target_layer',n.target_layer)$m$;
  definition := replace(definition, marker, replacement);
  execute definition;
end
$patch$;

-- Приказы передвижения: игроку и администратору.
do $patch$
declare definition text;
begin
  select pg_get_functiondef('fauxlore.military_order_api(text,bigint,jsonb)'::regprocedure) into definition;
  definition := replace(definition,
    'insert into fauxlore.notifications(account_id,kind,title,message)',
    'insert into fauxlore.notifications(account_id,kind,title,message,target_provinces,target_layer)');
  definition := replace(definition,
    $m$        case action when 'approve' then 'Приказ подтверждён: формирование перемещено.' when 'reject' then 'Приказ отклонён администратором.' else 'Приказ отменён.' end
      from fauxlore.account_states s where s.state_id=order_row.state_id;$m$,
    $m$        case action when 'approve' then 'Приказ подтверждён: формирование перемещено.' when 'reject' then 'Приказ отклонён администратором.' else 'Приказ отменён.' end,
        order_row.route,'military'
      from fauxlore.account_states s where s.state_id=order_row.state_id;$m$);
  definition := replace(definition,
    $m$    select a.id,'military_order','Новый приказ о передвижении',formation_row.name||': '||array_to_string(route_ids,' → ')
    from fauxlore.accounts a where a.role='admin';$m$,
    $m$    select a.id,'military_order','Новый приказ о передвижении',formation_row.name||': '||array_to_string(route_ids,' → '),
      route_ids,'military'
    from fauxlore.accounts a where a.role='admin';$m$);
  execute definition;
end
$patch$;

-- Колонизация: попытка.
do $patch$
declare definition text;
begin
  select pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure) into definition;
  definition := replace(definition,
    'insert into fauxlore.notifications(account_id,kind,title,message)',
    'insert into fauxlore.notifications(account_id,kind,title,message,target_provinces,target_layer)');
  definition := replace(definition,
    $m$      end)
  from (
    select distinct ast.account_id from fauxlore.account_states ast$m$,
    $m$      end),target_key,'states'
  from (
    select distinct ast.account_id from fauxlore.account_states ast$m$);
  execute definition;
end
$patch$;

-- Колонизация: завершение и срыв миссии.
do $patch$
declare definition text;
begin
  select pg_get_functiondef('fauxlore.advance_colonization_missions()'::regprocedure) into definition;
  definition := replace(definition,
    'insert into fauxlore.notifications(account_id,kind,title,message)',
    'insert into fauxlore.notifications(account_id,kind,title,message,target_provinces,target_layer)');
  definition := replace(definition,
    $m$||' прекращена: в казне не хватило средств на содержание. Провинция снова нейтральна.'
      from (select distinct ast.account_id$m$,
    $m$||' прекращена: в казне не хватило средств на содержание. Провинция снова нейтральна.',m.province_id,'states'
      from (select distinct ast.account_id$m$);
  definition := replace(definition,
    $m$||' теперь принадлежит государству и стала регионом.'
      from (select distinct ast.account_id$m$,
    $m$||' теперь принадлежит государству и стала регионом.',m.province_id,'states'
      from (select distinct ast.account_id$m$);
  execute definition;
end
$patch$;

-- Завоевание: успех и провал.
do $patch$
declare definition text;
begin
  select pg_get_functiondef('fauxlore.conquest_api(text,integer,jsonb)'::regprocedure) into definition;
  definition := replace(definition,
    'insert into fauxlore.notifications(account_id, kind, title, message)',
    'insert into fauxlore.notifications(account_id, kind, title, message, target_provinces, target_layer)');
  definition := replace(definition,
    $m$        p.name, final_value, roll_value, dice_detail, final_value, loss_pct)
    from (select distinct ast.account_id from fauxlore.account_states ast
          where ast.layer = 'states' and ast.state_id = state_key
          union select ac.id from fauxlore.accounts ac where ac.role = 'admin') recipients;$m$,
    $m$        p.name, final_value, roll_value, dice_detail, final_value, loss_pct),target_key,'military'
    from (select distinct ast.account_id from fauxlore.account_states ast
          where ast.layer = 'states' and ast.state_id = state_key
          union select ac.id from fauxlore.accounts ac where ac.role = 'admin') recipients;$m$);
  definition := replace(definition,
    $m$        p.name, final_value, roll_value, dice_detail, final_value, loss_pct)
    from (select distinct ast.account_id from fauxlore.account_states ast
          where ast.layer = 'states' and ast.state_id = state_key
          union select ac.id from fauxlore.accounts ac where ac.role = 'admin') recipients;$m$,
    $m$        p.name, final_value, roll_value, dice_detail, final_value, loss_pct),target_key,'military'
    from (select distinct ast.account_id from fauxlore.account_states ast
          where ast.layer = 'states' and ast.state_id = state_key
          union select ac.id from fauxlore.accounts ac where ac.role = 'admin') recipients;$m$);
  execute definition;
end
$patch$;

-- Строительство гарнизонов и портов.
do $patch$
declare definition text;
begin
  select pg_get_functiondef('fauxlore.notify_garrison_project_started()'::regprocedure) into definition;
  definition := replace(definition,
    'insert into fauxlore.notifications(account_id,kind,title,message)',
    'insert into fauxlore.notifications(account_id,kind,title,message,target_provinces,target_layer)');
  definition := replace(definition,
    $m$'.'
    from fauxlore.account_states a where a.state_id=new.state_id;$m$,
    $m$'.',new.province_id,'military'
    from fauxlore.account_states a where a.state_id=new.state_id;$m$);
  execute definition;
end
$patch$;

do $patch$
declare definition text;
begin
  select pg_get_functiondef('fauxlore.complete_garrison_projects()'::regprocedure) into definition;
  definition := replace(definition,
    'insert into fauxlore.notifications(account_id,kind,title,message)',
    'insert into fauxlore.notifications(account_id,kind,title,message,target_provinces,target_layer)');
  definition := replace(definition,
    $m$' построены.'
    from fauxlore.account_states a join fauxlore.provinces p on p.id=project_row.province_id$m$,
    $m$' построены.',project_row.province_id,'military'
    from fauxlore.account_states a join fauxlore.provinces p on p.id=project_row.province_id$m$);
  execute definition;
end
$patch$;

do $patch$
declare definition text;
begin
  select pg_get_functiondef('fauxlore.military_start_port_construction(integer,jsonb)'::regprocedure) into definition;
  definition := replace(definition,
    'insert into fauxlore.notifications(account_id,kind,title,message)',
    'insert into fauxlore.notifications(account_id,kind,title,message,target_provinces,target_layer)');
  definition := replace(definition,
    $m$'». Завершение — после следующего хода.'
   from fauxlore.account_states a where a.state_id=sid;$m$,
    $m$'». Завершение — после следующего хода.',province_key,'military'
   from fauxlore.account_states a where a.state_id=sid;$m$);
  execute definition;
end
$patch$;

do $patch$
declare definition text;
begin
  select pg_get_functiondef('fauxlore.complete_military_port_projects()'::regprocedure) into definition;
  definition := replace(definition,
    'insert into fauxlore.notifications(account_id,kind,title,message)',
    'insert into fauxlore.notifications(account_id,kind,title,message,target_provinces,target_layer)');
  definition := replace(definition,
    $m$'» построен и готов к использованию.'
      from fauxlore.account_states a where a.state_id=project_row.state_id;$m$,
    $m$'» построен и готов к использованию.',project_row.sea_province_id,'military'
      from fauxlore.account_states a where a.state_id=project_row.state_id;$m$);
  execute definition;
end
$patch$;
