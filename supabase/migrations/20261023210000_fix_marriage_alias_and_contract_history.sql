-- Avoid the account variable/table alias collision and expose completed marriage proposals to diplomacy.
do $$
declare
  fn text;
  query_start integer;
  query_end integer;
  query_body text;
begin
  select pg_get_functiondef('fauxlore.marriage_dissolution_api(text,text,jsonb,uuid)'::regprocedure) into fn;
  query_start:=strpos(fn,'select coalesce(jsonb_agg(jsonb_build_object(');
  query_end:=query_start+strpos(substring(fn from query_start),'return result;')-1;
  if query_start=0 or query_end=0 then raise exception 'Could not locate marriage list query'; end if;
  query_body:=substring(fn from query_start for query_end-query_start);
  query_body:=replace(query_body,'join fauxlore.state_characters a on a.id=','join fauxlore.state_characters person_a on person_a.id=');
  query_body:=replace(query_body,'join fauxlore.state_characters b on b.id=','join fauxlore.state_characters person_b on person_b.id=');
  query_body:=replace(query_body,'a.','person_a.');
  query_body:=replace(query_body,'b.','person_b.');
  fn:=overlay(fn placing query_body from query_start for query_end-query_start);
  execute fn;

  select pg_get_functiondef('fauxlore.dynastic_marriage_api(text,text,jsonb,uuid)'::regprocedure) into fn;
  fn:=replace(fn,$old$'id',p.id,'from_state_id'$old$,$new$'id',p.id,'status',p.status,'from_state_id'$new$);
  fn:=replace(fn,$old$where p.status='pending'$old$,$new$where true$new$);
  execute fn;
end $$;
notify pgrst,'reload schema';
