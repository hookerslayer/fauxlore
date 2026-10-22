-- The Stage 4 report subquery is keyed by recipient_id, not id.
do $$
declare fn text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.turn_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  if position('st.state_id=s.id' in fn)=0 then return; end if;
  execute replace(fn,'st.state_id=s.id','st.state_id=s.recipient_id');
end $$;
