-- Remove the unused magical principle and Tumen doctrine from live creation.
-- Existing magical choices are archived for audit and removed from active JSON.
create table if not exists fauxlore.retired_ephemeral_principles (
  state_id integer primary key,
  principle text not null,
  retired_at timestamptz not null default now()
);
revoke all on fauxlore.retired_ephemeral_principles from public,anon,authenticated;
insert into fauxlore.retired_ephemeral_principles(state_id,principle)
select state_id,principles->>'ephemeral' from fauxlore.state_profiles
where principles ? 'ephemeral'
on conflict (state_id) do nothing;
update fauxlore.state_profiles set principles=principles-'ephemeral'
where principles ? 'ephemeral';
update fauxlore.state_applications set principles=principles-'ephemeral'
where principles ? 'ephemeral';

do $migration$
declare fn text; old_text text; new_text text; function_name text;
begin
  select pg_get_functiondef(p.oid) into fn from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='fauxlore' and p.proname='government_form_raw';
  old_text:='array[''Сословная армия'',''Кондотьеры'',''Фирд'',''Гвардия'',''Тумены'']';
  if fn is null or position(old_text in fn)=0 then raise exception 'Unexpected government_form_raw doctrine list'; end if;
  fn:=replace(fn,old_text,'array[''Сословная армия'',''Кондотьеры'',''Фирд'',''Гвардия'']');
  old_text:='(military=''Тумены'' and (economy=any(array[''Гильдии'',''Адмиралтейство'',''Корсарство'']) or structure=any(array[''Консорциум'',''Командорство'']))) or';
  if position(old_text in fn)=0 then raise exception 'Unexpected government_form_raw conflict rule'; end if;
  fn:=replace(fn,old_text,'');
  execute fn;

  select pg_get_functiondef(p.oid) into fn from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='fauxlore' and p.proname='registration_api';
  old_text:='array[''authority'',''structure'',''economy'',''military'',''ephemeral'']';
  if fn is null or position(old_text in fn)=0 then raise exception 'Unexpected registration_api principle fields'; end if;
  fn:=replace(fn,old_text,'array[''authority'',''structure'',''economy'',''military'']');
  fn:=replace(fn,'))<>5 then', '))<>4 then');
  fn:=replace(fn,'Заполните все пять принципов государства','Заполните все четыре принципа государства');
  execute fn;

  select pg_get_functiondef(p.oid) into fn from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='fauxlore' and p.proname='state_api';
  if fn is null then raise exception 'Missing state_api'; end if;
  old_text:='if body->>''ephemeral'' is null or body->>''ephemeral''<>all(array[''Мораторий'',''Придворные чародеи'',''Герметизм'',''Святые Таинства'',''Артефакторика'']) then raise sqlstate ''22023'' using message=''Неизвестный эфемерный принцип''; end if;';
  if position(old_text in fn)=0 then raise exception 'Unexpected state_api magical principle validation'; end if;
  fn:=replace(fn,old_text,'');
  old_text:='''military'',body->>''military'',''ephemeral'',body->>''ephemeral''';
  if position(old_text in fn)=0 then raise exception 'Unexpected state_api principle payload'; end if;
  fn:=replace(fn,old_text,'''military'',body->>''military''');
  old_text:='''military'',''ephemeral'',';
  if position(old_text in fn)=0 then raise exception 'Unexpected state_api allowed fields'; end if;
  fn:=replace(fn,old_text,'''military'',');
  execute fn;
end $migration$;
