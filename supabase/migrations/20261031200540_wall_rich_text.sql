alter table fauxlore.wall_posts add column rich_body jsonb;

create function fauxlore.wall_document_text(document jsonb) returns text
language plpgsql immutable set search_path='' as $$
declare block jsonb; span jsonb; result text := ''; block_text text; first_block boolean := true;
begin
  if jsonb_typeof(document) <> 'array' or jsonb_array_length(document) > 30000 or pg_column_size(document) > 1000000 then
    raise sqlstate '22023' using message='Неверный формат поста';
  end if;
  for block in select value from jsonb_array_elements(document) loop
    if jsonb_typeof(block) <> 'object' or coalesce(block->>'type','') not in ('p','h2','h3','ul','ol') or jsonb_typeof(block->'spans') is distinct from 'array' then
      raise sqlstate '22023' using message='Неверный формат поста';
    end if;
    block_text := '';
    for span in select value from jsonb_array_elements(block->'spans') loop
      if jsonb_typeof(span) <> 'object' or jsonb_typeof(span->'text') is distinct from 'string'
         or (span ? 'bold' and jsonb_typeof(span->'bold') <> 'boolean')
         or (span ? 'italic' and jsonb_typeof(span->'italic') <> 'boolean')
         or (span ? 'underline' and jsonb_typeof(span->'underline') <> 'boolean') then
        raise sqlstate '22023' using message='Неверный формат поста';
      end if;
      block_text := block_text || (span->>'text');
      if length(block_text)>30000 then raise sqlstate '22023' using message='Пост должен содержать от 1500 до 30000 символов'; end if;
    end loop;
    if not first_block then result := result || E'\n'; end if;
    result := result || block_text;
    first_block := false;
    if length(result)>30002 then raise sqlstate '22023' using message='Пост должен содержать от 1500 до 30000 символов'; end if;
  end loop;
  return btrim(result, E' \t\n\r');
end $$;
revoke all on function fauxlore.wall_document_text(jsonb) from public, anon, authenticated;

do $$
declare definition text;
begin
  definition := pg_get_functiondef('fauxlore.wall_api(text,jsonb)'::regprocedure);
  if position('''id'',p.id,''body'',p.body,''images'',p.images' in definition)=0
     or position('body_value:=btrim(coalesce(payload->>''body'',''''));' in definition)=0
     or position('returning id into new_id;' in definition)=0 then
    raise exception 'Wall API hooks missing';
  end if;
  definition := replace(definition, '''id'',p.id,''body'',p.body,''images'',p.images', '''id'',p.id,''body'',p.body,''rich_body'',p.rich_body,''images'',p.images');
  definition := replace(definition, 'body_value:=btrim(coalesce(payload->>''body'',''''));' || chr(10) || '    if length(body_value) not between 1500 and 30000',
    'body_value:=case when payload ? ''rich_body'' then fauxlore.wall_document_text(payload->''rich_body'') else btrim(coalesce(payload->>''body'','''')) end;' || chr(10) || '    if length(body_value) not between 1500 and 30000');
  definition := replace(definition, 'returning id into new_id;' || chr(10) || '    if coalesce((payload->>''needs_verdict'')',
    'returning id into new_id;' || chr(10) || '    if payload ? ''rich_body'' then update fauxlore.wall_posts set rich_body=payload->''rich_body'' where id=new_id; end if;' || chr(10) || '    if coalesce((payload->>''needs_verdict'')');
  if position('fauxlore.wall_document_text(payload->''rich_body'')' in definition)=0 or position('set rich_body=payload->''rich_body''' in definition)=0 then raise exception 'Wall API update failed'; end if;
  execute definition;
end $$;
notify pgrst,'reload schema';
