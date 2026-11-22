-- Реакции на комментарии Стены: лайк/дизлайк, по одной реакции на аккаунт.
do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to patch wall comments outside production candidate';
  end if;
end
$guard$;

create table if not exists fauxlore.wall_comment_reactions(
  comment_id bigint not null references fauxlore.wall_comments(id) on delete cascade,
  account_id bigint not null references fauxlore.accounts(id),
  reaction text not null check(reaction in ('like','dislike')),
  created_at timestamptz not null default now(),
  primary key(comment_id,account_id)
);
create index if not exists wall_comment_reactions_comment_idx
  on fauxlore.wall_comment_reactions(comment_id,reaction);
alter table fauxlore.wall_comment_reactions enable row level security;
revoke all on fauxlore.wall_comment_reactions from public,anon,authenticated;

do $patch$
declare definition text; marker text;
begin
  select pg_get_functiondef('fauxlore.wall_api(text,jsonb)'::regprocedure) into definition;

  marker := $m$declare actor fauxlore.accounts; sid integer; pid bigint; verdict_state integer;$m$;
  if position(marker in definition) = 0 then raise exception 'wall_api declarations changed'; end if;
  definition := replace(definition, marker,
    $m$declare actor fauxlore.accounts; sid integer; pid bigint; cid bigint; verdict_state integer;$m$);

  marker := $m$'role',ca.role,'state',cs.name) order by c.created_at,c.id$m$;
  if position(marker in definition) = 0 then raise exception 'wall comment projection changed'; end if;
  definition := replace(definition, marker,
    $m$'role',ca.role,'state',cs.name,
      'likes',(select count(*) from fauxlore.wall_comment_reactions cr where cr.comment_id=c.id and cr.reaction='like'),
      'dislikes',(select count(*) from fauxlore.wall_comment_reactions cr where cr.comment_id=c.id and cr.reaction='dislike'),
      'my_reaction',(select cr.reaction from fauxlore.wall_comment_reactions cr where cr.comment_id=c.id and cr.account_id=actor.id)) order by c.created_at,c.id$m$);

  marker := $m$  elsif action='verdict' then$m$;
  if position(marker in definition) = 0 then raise exception 'wall verdict action changed'; end if;
  definition := replace(definition, marker,
    $m$  elsif action='react_comment' then
    cid:=(payload->>'comment_id')::bigint;
    if payload->>'reaction' not in ('like','dislike') then raise sqlstate '22023' using message='Неизвестная реакция'; end if;
    if not exists(select 1 from fauxlore.wall_comments where id=cid) then raise sqlstate 'P0002' using message='Комментарий не найден'; end if;
    if exists(select 1 from fauxlore.wall_comment_reactions where comment_id=cid and account_id=actor.id and reaction=payload->>'reaction') then
      delete from fauxlore.wall_comment_reactions where comment_id=cid and account_id=actor.id;
    else
      insert into fauxlore.wall_comment_reactions(comment_id,account_id,reaction) values(cid,actor.id,payload->>'reaction')
      on conflict(comment_id,account_id) do update set reaction=excluded.reaction;
    end if;
    return jsonb_build_object('ok',true);
  elsif action='verdict' then$m$);

  execute definition;
end
$patch$;
