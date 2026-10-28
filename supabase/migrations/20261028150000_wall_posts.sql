create table fauxlore.wall_posts(id bigint generated always as identity primary key,account_id bigint not null references fauxlore.accounts(id),state_id integer references fauxlore.state_profiles(state_id),body text not null check(length(body) between 1500 and 30000),images jsonb not null default '[]'::jsonb check(jsonb_typeof(images)='array' and jsonb_array_length(images)<=2),needs_verdict boolean not null default false,created_at timestamptz not null default now());
create table fauxlore.wall_comments(id bigint generated always as identity primary key,post_id bigint not null references fauxlore.wall_posts(id) on delete cascade,account_id bigint not null references fauxlore.accounts(id),body text not null check(length(body) between 1 and 3000),created_at timestamptz not null default now());
create table fauxlore.wall_reactions(post_id bigint not null references fauxlore.wall_posts(id) on delete cascade,account_id bigint not null references fauxlore.accounts(id),reaction text not null check(reaction in ('like','dislike')),primary key(post_id,account_id));
create table fauxlore.wall_verdicts(post_id bigint primary key references fauxlore.wall_posts(id) on delete cascade,admin_account_id bigint not null references fauxlore.accounts(id),state_id integer not null references fauxlore.state_profiles(state_id),body text not null,treasury_expense integer not null default 0 check(treasury_expense>=0),prestige_expense integer not null default 0 check(prestige_expense>=0),created_at timestamptz not null default now());
create index wall_posts_created_idx on fauxlore.wall_posts(created_at desc,id desc);
create index wall_comments_post_idx on fauxlore.wall_comments(post_id,created_at);
alter table fauxlore.wall_posts enable row level security;
alter table fauxlore.wall_comments enable row level security;
alter table fauxlore.wall_reactions enable row level security;
alter table fauxlore.wall_verdicts enable row level security;
revoke all on fauxlore.wall_posts,fauxlore.wall_comments,fauxlore.wall_reactions,fauxlore.wall_verdicts from public,anon,authenticated;

create or replace function fauxlore.wall_api(action text,payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; sid integer; pid bigint; verdict_state integer; expense_g integer; expense_op integer; image_item text; image_count integer; body_value text; new_id bigint; item jsonb; effect_payload jsonb; verdict_mods jsonb; verdict_row record; current_balance numeric;
begin
  actor:=fauxlore.current_account();
  if action='list' then
    return coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'body',p.body,'images',p.images,'needs_verdict',p.needs_verdict,'created_at',p.created_at,
      'author',a.nickname,'avatar',case when a.avatar_base64 is not null and a.avatar_type is not null then 'data:'||a.avatar_type||';base64,'||a.avatar_base64 else null end,
      'role',a.role,'state',s.name,'likes',(select count(*) from fauxlore.wall_reactions r where r.post_id=p.id and r.reaction='like'),
      'dislikes',(select count(*) from fauxlore.wall_reactions r where r.post_id=p.id and r.reaction='dislike'),
      'my_reaction',(select r.reaction from fauxlore.wall_reactions r where r.post_id=p.id and r.account_id=actor.id),
      'comments',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'body',c.body,'created_at',c.created_at,'author',ca.nickname,'avatar',case when ca.avatar_base64 is not null and ca.avatar_type is not null then 'data:'||ca.avatar_type||';base64,'||ca.avatar_base64 else null end,'role',ca.role,'state',cs.name) order by c.created_at,c.id) from fauxlore.wall_comments c join fauxlore.accounts ca on ca.id=c.account_id left join fauxlore.account_states cas on cas.account_id=ca.id and cas.layer='states' left join fauxlore.map_categories cs on cs.layer='states' and cs.id=cas.state_id where c.post_id=p.id),'[]'::jsonb),
      'verdict',(select jsonb_build_object('body',v.body,'state',vs.name,'treasury_expense',v.treasury_expense,'prestige_expense',v.prestige_expense,'created_at',v.created_at) from fauxlore.wall_verdicts v join fauxlore.map_categories vs on vs.layer='states' and vs.id=v.state_id where v.post_id=p.id)) order by p.created_at desc,p.id desc)
      from (select * from fauxlore.wall_posts order by created_at desc,id desc limit 30 offset greatest(0,least(100000,coalesce((payload->>'offset')::integer,0)))) p
      join fauxlore.accounts a on a.id=p.account_id left join fauxlore.map_categories s on s.layer='states' and s.id=p.state_id),'[]'::jsonb);
  end if;
  if actor.id is null then raise sqlstate '42501' using message='Войдите в аккаунт'; end if;
  if action='create' then
    body_value:=btrim(coalesce(payload->>'body',''));
    if length(body_value) not between 1500 and 30000 then raise sqlstate '22023' using message='Пост должен содержать от 1500 до 30000 символов'; end if;
    if jsonb_typeof(coalesce(payload->'images','[]'::jsonb))<>'array' or jsonb_array_length(coalesce(payload->'images','[]'::jsonb))>2 then raise sqlstate '22023' using message='Допустимо не более двух изображений'; end if;
    for image_item in select value from jsonb_array_elements_text(coalesce(payload->'images','[]'::jsonb)) value loop
      if image_item !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$' or length(image_item)>2800000 then raise sqlstate '22023' using message='Изображение должно быть JPG, PNG или WebP, до 2 МБ'; end if;
      if octet_length(decode(split_part(image_item,',',2),'base64'))>2097152 then raise sqlstate '22023' using message='Изображение превышает 2 МБ'; end if;
    end loop;
    if actor.role<>'admin' then
      select state_id into sid from fauxlore.account_states where account_id=actor.id and layer='states' order by state_id limit 1;
      if sid is null then raise sqlstate '42501' using message='Публиковать могут только игроки с государством'; end if;
      update fauxlore.state_profiles set prestige=prestige-3 where state_id=sid and prestige>=3;
      if not found then raise sqlstate '22023' using message='Для публикации нужно 3 ОП'; end if;
    end if;
    insert into fauxlore.wall_posts(account_id,state_id,body,images,needs_verdict) values(actor.id,sid,body_value,coalesce(payload->'images','[]'::jsonb),coalesce((payload->>'needs_verdict')::boolean,false)) returning id into new_id;
    if coalesce((payload->>'needs_verdict')::boolean,false) and actor.role<>'admin' then
      insert into fauxlore.notifications(account_id,kind,title,message) select id,'wall_verdict_request','Пост ожидает вердикта','Пост №'||new_id||' от государства требует вердикта администратора.' from fauxlore.accounts where role='admin';
    end if;
    return jsonb_build_object('id',new_id);
  elsif action='comment' then
    pid:=(payload->>'post_id')::bigint; body_value:=btrim(coalesce(payload->>'body',''));
    if length(body_value) not between 1 and 3000 then raise sqlstate '22023' using message='Комментарий должен содержать от 1 до 3000 символов'; end if;
    if not exists(select 1 from fauxlore.wall_posts where id=pid) then raise sqlstate 'P0002' using message='Пост не найден'; end if;
    insert into fauxlore.wall_comments(post_id,account_id,body) values(pid,actor.id,body_value) returning id into new_id;
    return jsonb_build_object('id',new_id);
  elsif action='react' then
    pid:=(payload->>'post_id')::bigint;
    if payload->>'reaction' not in ('like','dislike') then raise sqlstate '22023' using message='Неизвестная реакция'; end if;
    if not exists(select 1 from fauxlore.wall_posts where id=pid) then raise sqlstate 'P0002' using message='Пост не найден'; end if;
    if exists(select 1 from fauxlore.wall_reactions where post_id=pid and account_id=actor.id and reaction=payload->>'reaction') then
      delete from fauxlore.wall_reactions where post_id=pid and account_id=actor.id;
    else insert into fauxlore.wall_reactions(post_id,account_id,reaction) values(pid,actor.id,payload->>'reaction') on conflict(post_id,account_id) do update set reaction=excluded.reaction; end if;
    return jsonb_build_object('ok',true);
  elsif action='verdict' then
    if actor.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
    pid:=(payload->>'post_id')::bigint; verdict_state:=(payload->>'state_id')::integer;body_value:=btrim(coalesce(payload->>'body',''));
    expense_g:=coalesce((payload->>'treasury_expense')::integer,0);expense_op:=coalesce((payload->>'prestige_expense')::integer,0);
    if length(body_value) not between 1 and 10000 or expense_g<0 or expense_op<0 or verdict_state is null then raise sqlstate '22023' using message='Проверьте вердикт и расходы'; end if;
    perform 1 from fauxlore.wall_posts where id=pid for update;
    if not found then raise sqlstate 'P0002' using message='Пост не найден'; end if;
    if not exists(select 1 from fauxlore.state_profiles where state_id=verdict_state) then raise sqlstate 'P0002' using message='Государство не найдено'; end if;
    insert into fauxlore.wall_verdicts(post_id,admin_account_id,state_id,body,treasury_expense,prestige_expense) values(pid,actor.id,verdict_state,body_value,expense_g,expense_op);
    if expense_g>0 then
      update fauxlore.state_treasuries set balance=balance-expense_g where state_id=verdict_state and estate='Корона' and balance>=expense_g;
      if not found then raise sqlstate '22023' using message='Недостаточно средств в Казне'; end if;
      update fauxlore.state_profiles set treasury=treasury-expense_g where state_id=verdict_state;
    end if;
    if expense_op>0 then
      update fauxlore.state_profiles set prestige=prestige-expense_op where state_id=verdict_state and prestige>=expense_op;
      if not found then raise sqlstate '22023' using message='Недостаточно ОП'; end if;
    end if;
    verdict_mods:=coalesce(payload->'modifiers','[]'::jsonb);
    if jsonb_typeof(verdict_mods)<>'array' or jsonb_array_length(verdict_mods)>10 then raise sqlstate '22023' using message='Допустимо не более десяти модификаторов'; end if;
    for item in select value from jsonb_array_elements(verdict_mods) value loop
      effect_payload:=item||jsonb_build_object('state_id',verdict_state,'target_kind',case when item->>'province_id' is null then 'state' else 'province' end);
      perform fauxlore.admin_modifiers_api('assign',effect_payload);
    end loop;
    insert into fauxlore.notifications(account_id,kind,title,message) select account_id,'wall_verdict','Вердикт на пост','Администратор вынес вердикт по посту №'||pid||'.' from fauxlore.account_states where layer='states' and state_id=verdict_state;
    return jsonb_build_object('post_id',pid,'state_id',verdict_state);
  end if;
  raise sqlstate '22023' using message='Неизвестное действие Стены';
end $function$;
revoke all on function fauxlore.wall_api(text,jsonb) from public,anon,authenticated;
grant execute on function fauxlore.wall_api(text,jsonb) to anon,authenticated;
create or replace function public.wall_api(action text,payload jsonb default '{}'::jsonb)
returns jsonb language sql security invoker set search_path=pg_catalog,fauxlore as $$select fauxlore.wall_api(action,payload)$$;
revoke all on function public.wall_api(text,jsonb) from public;
grant execute on function public.wall_api(text,jsonb) to anon,authenticated;
notify pgrst,'reload schema';
