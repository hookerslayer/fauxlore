alter table fauxlore.state_profiles
  add column if not exists ruler_surname text not null default '';
alter table fauxlore.state_applications
  add column if not exists ruler_surname text not null default '';

create table if not exists fauxlore.state_characters (
  id bigint generated always as identity primary key,
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 120),
  surname text not null default '' check (length(surname) <= 120),
  gender text not null check (gender in ('Мужской','Женский','Иной')),
  title text not null default '' check (length(title) <= 100),
  age smallint not null check (age between 0 and 250),
  race_id integer not null,
  religion_id integer not null,
  alive boolean not null default true,
  legitimacy text not null default 'Неприменимо'
    check (legitimacy in ('Законный','Незаконный','Неприменимо')),
  is_current_ruler boolean not null default false,
  is_regent boolean not null default false,
  father_id bigint references fauxlore.state_characters(id) on delete set null,
  mother_id bigint references fauxlore.state_characters(id) on delete set null,
  died_at_turn integer,
  created_at timestamptz not null default now(),
  unique (id,state_id),
  check (father_id is null or father_id<>id),
  check (mother_id is null or mother_id<>id),
  check (father_id is null or mother_id is null or father_id<>mother_id)
);
create unique index if not exists state_characters_one_ruler_idx
  on fauxlore.state_characters(state_id) where is_current_ruler;
create index if not exists state_characters_family_idx
  on fauxlore.state_characters(state_id,alive,age);

create table if not exists fauxlore.state_marriages (
  id bigint generated always as identity primary key,
  character_a_id bigint not null references fauxlore.state_characters(id) on delete cascade,
  character_b_id bigint not null references fauxlore.state_characters(id) on delete cascade,
  marriage_type text not null check (marriage_type in ('local','dynastic')),
  lawful_for_a boolean not null default false,
  lawful_for_b boolean not null default false,
  started_at_turn integer not null,
  ended_at_turn integer,
  created_at timestamptz not null default now(),
  check (character_a_id<>character_b_id),
  check (ended_at_turn is null or ended_at_turn>=started_at_turn)
);
create index if not exists state_marriages_a_idx on fauxlore.state_marriages(character_a_id);
create index if not exists state_marriages_b_idx on fauxlore.state_marriages(character_b_id);
alter table fauxlore.state_characters enable row level security;
alter table fauxlore.state_marriages enable row level security;
revoke all on fauxlore.state_characters,fauxlore.state_marriages from public,anon,authenticated;

insert into fauxlore.state_characters(state_id,name,surname,gender,title,age,race_id,religion_id,is_current_ruler)
select sp.state_id,btrim(sp.ruler_name),coalesce(sp.ruler_surname,''),coalesce(sp.ruler_gender,'Иной'),
       coalesce(sp.ruler_title,''),greatest(0,least(250,coalesce(sp.ruler_age,30))),
       sp.official_race_id,sp.official_religion_id,true
from fauxlore.state_profiles sp
where nullif(btrim(sp.ruler_name),'') is not null
  and not exists(select 1 from fauxlore.state_characters ch where ch.state_id=sp.state_id and ch.is_current_ruler);

create or replace function fauxlore.state_characters_payload(target_state_id integer)
returns jsonb language sql security definer set search_path='' as $$
  with ruler as (
    select ch.* from fauxlore.state_characters ch
    where ch.state_id=target_state_id and ch.is_current_ruler limit 1
  ), relevant as (
    select distinct ch.*,
      case
        when ch.is_current_ruler then 'Правитель'
        when exists(select 1 from fauxlore.state_marriages m
          where ((m.character_a_id=ch.id and m.character_b_id=(select id from ruler))
             or (m.character_b_id=ch.id and m.character_a_id=(select id from ruler))))
          then case when exists(select 1 from fauxlore.state_marriages m
            where m.ended_at_turn is null and
              ((m.character_a_id=ch.id and m.character_b_id=(select id from ruler))
                or (m.character_b_id=ch.id and m.character_a_id=(select id from ruler))))
            then case when ch.gender='Женский' then 'Супруга' else 'Супруг' end
            else 'Бывший супруг' end
        when ch.id in ((select father_id from ruler),(select mother_id from ruler)) then 'Родитель'
        when (select id from ruler) in (ch.father_id,ch.mother_id) then 'Ребёнок'
        when exists(select 1 from fauxlore.state_characters rr where rr.id=(select id from ruler)
          and ((rr.father_id is not null and rr.father_id in (ch.father_id,ch.mother_id))
            or (rr.mother_id is not null and rr.mother_id in (ch.father_id,ch.mother_id)))) then 'Брат/сестра'
        else 'Родственник'
      end as relation
    from fauxlore.state_characters ch
    where ch.state_id=target_state_id
      and (ch.is_current_ruler or ch.id in ((select father_id from ruler),(select mother_id from ruler))
        or (select id from ruler) in (ch.father_id,ch.mother_id)
        or exists(select 1 from fauxlore.state_marriages m
          where (m.character_a_id=ch.id and m.character_b_id=(select id from ruler))
             or (m.character_b_id=ch.id and m.character_a_id=(select id from ruler)))
        or exists(select 1 from fauxlore.state_characters rr where rr.id=(select id from ruler)
          and ((rr.father_id is not null and rr.father_id in (ch.father_id,ch.mother_id))
            or (rr.mother_id is not null and rr.mother_id in (ch.father_id,ch.mother_id)))))
    union
    select ch.*,
      case when ch.gender='Женский' then 'Супруга' else 'Супруг' end as relation
    from fauxlore.state_marriages m
    join fauxlore.state_characters ch on ch.id=case when m.character_a_id=(select id from ruler) then m.character_b_id else m.character_a_id end
    where (m.character_a_id=(select id from ruler) or m.character_b_id=(select id from ruler))
      and ch.state_id<>target_state_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'name',r.name,'surname',r.surname,'gender',r.gender,'title',r.title,
    'age',r.age,'race_id',r.race_id,'religion_id',r.religion_id,
    'race',(select c.name from fauxlore.map_categories c where c.layer='races' and c.id=r.race_id),
    'religion',(select c.name from fauxlore.map_categories c where c.layer='religions' and c.id=r.religion_id),
    'alive',r.alive,'legitimacy',r.legitimacy,'is_current_ruler',r.is_current_ruler,
    'is_regent',r.is_regent,'relationship',r.relation,
    'state_name',(select c.name from fauxlore.map_categories c where c.layer='states' and c.id=r.state_id)
  ) order by r.is_current_ruler desc,r.age desc,r.id), '[]'::jsonb)
  from relevant r
$$;
revoke all on function fauxlore.state_characters_payload(integer) from public,anon,authenticated;

create or replace function fauxlore.characters_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; state_value integer; result jsonb;
begin
  if method<>'GET' or body<>'{}'::jsonb then
    raise sqlstate '22023' using message='Недопустимый запрос';
  end if;
  a:=fauxlore.current_account();
  if path ~ '^my/states/[0-9]+/characters$' then
    state_value:=split_part(path,'/',3)::integer;
    if not exists(select 1 from fauxlore.account_states ast where ast.account_id=a.id and ast.state_id=state_value) then
      raise sqlstate '42501' using message='Нет доступа к этому государству';
    end if;
  elsif path ~ '^admin/states/[0-9]+/characters$' then
    if a.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
    state_value:=split_part(path,'/',3)::integer;
  else
    raise sqlstate '22023' using message='Некорректный запрос';
  end if;
  if not exists(select 1 from fauxlore.state_profiles where state_id=state_value) then
    raise sqlstate 'P0002' using message='Государство не найдено';
  end if;
  result:=fauxlore.state_characters_payload(state_value);
  return result;
end $$;
revoke all on function fauxlore.characters_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.characters_api(text,text,jsonb,uuid) to authenticated;

create or replace function public.fauxlore_api(path text,method text default 'GET',body jsonb default '{}',request_id uuid default null)
returns jsonb language sql security invoker set search_path='' as $$
  select case
    when path ~ '^my/states/[0-9]+/characters$' or path ~ '^admin/states/[0-9]+/characters$'
      then fauxlore.characters_api(path,method,body,request_id)
    when path='admin/states' then fauxlore.state_api(path,method,body,request_id)
    else fauxlore.api(path,method,body,request_id)
  end
$$;
revoke all on function public.fauxlore_api(text,text,jsonb,uuid) from public;
grant execute on function public.fauxlore_api(text,text,jsonb,uuid) to anon,authenticated;
notify pgrst,'reload schema';
