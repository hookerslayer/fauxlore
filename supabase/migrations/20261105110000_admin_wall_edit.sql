alter table fauxlore.wall_posts drop constraint wall_posts_body_check;
alter table fauxlore.wall_posts add constraint wall_posts_body_check check (length(body) between 1 and 30000);
do $migration$
declare fn text; marker text; replacement text;
begin
 fn:=pg_get_functiondef('fauxlore.wall_api(text,jsonb)'::regprocedure);
 marker:=$old$'id',p.id,'can_verdict'$old$; replacement:=$new$'id',p.id,'can_edit',coalesce(actor.role='admin' and p.account_id=actor.id,false),'can_verdict'$new$;
 if position(marker in fn)=0 then raise exception 'Wall post list hook missing'; end if; fn:=replace(fn,marker,replacement);
 marker:=$old$'id',c.id,'body',c.body,'created_at'$old$; replacement:=$new$'id',c.id,'can_edit',coalesce(actor.role='admin' and c.account_id=actor.id,false),'body',c.body,'created_at'$new$;
 if position(marker in fn)=0 then raise exception 'Wall comment list hook missing'; end if; fn:=replace(fn,marker,replacement);
 marker:=$old$if length(body_value) not between 1500 and 30000 then raise sqlstate '22023' using message='Пост должен содержать от 1500 до 30000 символов'; end if;$old$;
 replacement:=$new$if length(body_value)>30000 or length(body_value)<(case when actor.role='admin' then 1 else 1500 end) then raise sqlstate '22023' using message=(case when actor.role='admin' then 'Пост должен содержать от 1 до 30000 символов' else 'Пост должен содержать от 1500 до 30000 символов' end); end if;$new$;
 if position(marker in fn)=0 then raise exception 'Wall length hook missing'; end if; fn:=replace(fn,marker,replacement);
 marker:=$old$  if action='delete' then$old$;
 replacement:=$new$  if action in ('edit_post','edit_comment') then
    if actor.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
    if action='edit_post' then
      body_value:=case when payload ? 'rich_body' then fauxlore.wall_document_text(payload->'rich_body') else btrim(coalesce(payload->>'body','')) end;
      if length(body_value) not between 1 and 30000 then raise sqlstate '22023' using message='Пост должен содержать от 1 до 30000 символов'; end if;
      update fauxlore.wall_posts set body=body_value,rich_body=case when payload ? 'rich_body' then payload->'rich_body' else null end where id=(payload->>'post_id')::bigint and account_id=actor.id;
    else
      body_value:=btrim(coalesce(payload->>'body',''));
      if length(body_value) not between 1 and 3000 then raise sqlstate '22023' using message='Комментарий должен содержать от 1 до 3000 символов'; end if;
      update fauxlore.wall_comments set body=body_value where id=(payload->>'comment_id')::bigint and account_id=actor.id;
    end if;
    if not found then raise sqlstate '42501' using message='Можно редактировать только свои записи'; end if;
    return jsonb_build_object('updated',true);
  end if;
  if action='delete' then$new$;
 if position(marker in fn)=0 then raise exception 'Wall edit hook missing'; end if; execute replace(fn,marker,replacement);
end
$migration$;
