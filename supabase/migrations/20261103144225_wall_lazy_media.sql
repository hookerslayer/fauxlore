do $migration$
declare
  fn text := pg_get_functiondef('fauxlore.wall_api(text,jsonb)'::regprocedure);
  list_hook text := '  if action=''list'' then';
  image_hook text := '''images'',p.images';
  author_hook text := 'case when a.avatar_base64 is not null and a.avatar_type is not null then ''data:''||a.avatar_type||'';base64,''||a.avatar_base64 else null end';
  comment_hook text := 'case when ca.avatar_base64 is not null and ca.avatar_type is not null then ''data:''||ca.avatar_type||'';base64,''||ca.avatar_base64 else null end';
  media_action text := $sql$  if action='media' then
    return (select jsonb_build_object(
      'images',p.images,
      'avatar',case when a.avatar_base64 is not null and a.avatar_type is not null then 'data:'||a.avatar_type||';base64,'||a.avatar_base64 else null end,
      'comments',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'avatar',case when ca.avatar_base64 is not null and ca.avatar_type is not null then 'data:'||ca.avatar_type||';base64,'||ca.avatar_base64 else null end) order by c.created_at,c.id) from fauxlore.wall_comments c join fauxlore.accounts ca on ca.id=c.account_id where c.post_id=p.id),'[]'::jsonb))
      from fauxlore.wall_posts p join fauxlore.accounts a on a.id=p.account_id where p.id=(payload->>'post_id')::bigint);
  end if;
$sql$;
begin
  if position(list_hook in fn)=0 or position(image_hook in fn)=0 or position(author_hook in fn)=0 or position(comment_hook in fn)=0 then raise exception 'Wall media hooks missing'; end if;
  fn:=replace(fn,list_hook,media_action||list_hook);
  fn:=replace(fn,image_hook,'''images'',case when payload->>''defer_media''=''true'' then ''[]''::jsonb else p.images end');
  fn:=replace(fn,author_hook,'case when payload->>''defer_media''=''true'' and action=''list'' then null else '||author_hook||' end');
  fn:=replace(fn,comment_hook,'case when payload->>''defer_media''=''true'' and action=''list'' then null else '||comment_hook||' end');
  execute fn;
end $migration$;
notify pgrst,'reload schema';
