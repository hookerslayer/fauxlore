insert into fauxlore.permanent_modifier_definitions(source_kind,source_key,modifier_key,effect,value,unit,scope,condition_text) values
 ('constructor','Назначение','military_tradition_pp','Военные традиции',0,'п.п.','Государство',''),
 ('constructor','Назначение','naval_tradition_pp','Морские традиции',0,'п.п.','Государство','');
alter table fauxlore.military_traditions add column land_modifier_spent numeric not null default 0 check(land_modifier_spent>=0),
 add column naval_modifier_spent numeric not null default 0 check(naval_modifier_spent>=0);
create function fauxlore.effective_tradition(target_state integer,domain_value text) returns numeric
language sql stable security definer set search_path='' as $$
 select greatest(0,least(100,case when domain_value='land' then land-land_modifier_spent else naval-naval_modifier_spent end+
  100*fauxlore.state_permanent_modifier_total(target_state,array[case when domain_value='land' then 'military_tradition_pp' else 'naval_tradition_pp' end],null,null)))
 from fauxlore.military_traditions where state_id=target_state
$$;
revoke all on function fauxlore.effective_tradition(integer,text) from public,anon,authenticated;
create function fauxlore.spend_tradition(target_state integer,domain_value text,amount numeric) returns void
language plpgsql security definer set search_path='' as $$
declare effective numeric; modifier numeric; raw_value numeric;
begin
 if domain_value not in ('land','naval') or amount<0 then raise exception 'Invalid tradition operation';end if;
 perform 1 from fauxlore.military_traditions where state_id=target_state for update;
 effective:=fauxlore.effective_tradition(target_state,domain_value);
 modifier:=100*fauxlore.state_permanent_modifier_total(target_state,array[case when domain_value='land' then 'military_tradition_pp' else 'naval_tradition_pp' end],null,null);
 raw_value:=greatest(0,effective-amount)-modifier;
 if domain_value='land' then update fauxlore.military_traditions set land=greatest(0,least(100,raw_value)),land_modifier_spent=greatest(0,-raw_value) where state_id=target_state;
 else update fauxlore.military_traditions set naval=greatest(0,least(100,raw_value)),naval_modifier_spent=greatest(0,-raw_value) where state_id=target_state;end if;
end $$;
revoke all on function fauxlore.spend_tradition(integer,text,numeric) from public,anon,authenticated;
do $migration$
declare fn text; marker text;
begin
 fn:=replace(pg_get_functiondef('fauxlore.military_actions_extra(text,integer,jsonb)'::regprocedure),chr(13),'');
 marker:=$old$select case when payload->>'domain'='land' then land else naval end into tradition_value
    from fauxlore.military_traditions where state_id=sid for update;$old$;
 marker:=replace(marker,chr(13),'');if position(marker in fn)=0 then raise exception 'tradition hire read missing';end if;
 fn:=replace(fn,marker,$new$perform 1 from fauxlore.military_traditions where state_id=sid for update;
  tradition_value:=fauxlore.effective_tradition(sid,payload->>'domain');$new$);
 marker:=$old$update fauxlore.military_traditions set land=case when payload->>'domain'='land' then land-5 else land end,
    naval=case when payload->>'domain'='naval' then naval-5 else naval end where state_id=sid;$old$;
 marker:=replace(marker,chr(13),'');if position(marker in fn)=0 then raise exception 'tradition hire spend missing';end if;
 fn:=replace(fn,marker,$new$perform fauxlore.spend_tradition(sid,payload->>'domain',5);$new$);execute fn;
 fn:=replace(pg_get_functiondef('fauxlore.military_finish_turn()'::regprocedure),chr(13),'');
 marker:=$old$update fauxlore.military_traditions set land=greatest(0,land-2),naval=greatest(0,naval-2) where state_id=state_row.state_id;$old$;
 if position(marker in fn)=0 then raise exception 'tradition decay missing';end if;
 fn:=replace(fn,marker,$new$perform fauxlore.spend_tradition(state_row.state_id,'land',2);perform fauxlore.spend_tradition(state_row.state_id,'naval',2);$new$);execute fn;
 fn:=replace(pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure),chr(13),'');
 marker:=$old$(select to_jsonb(t)-'state_id' from fauxlore.military_traditions t where state_id=sid)$old$;
 if position(marker in fn)=0 then raise exception 'tradition snapshot missing';end if;
 fn:=replace(fn,marker,$new$(select jsonb_build_object('land',fauxlore.effective_tradition(sid,'land'),'naval',fauxlore.effective_tradition(sid,'naval')) from fauxlore.military_traditions t where state_id=sid)$new$);execute fn;
end $migration$;
notify pgrst,'reload schema';
