-- Show current tradeable surplus for the two selected states and expose state IDs in logs for scoped views.
create or replace function fauxlore.trade_availability_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor fauxlore.accounts; state_value integer;
begin
  actor:=fauxlore.current_account();
  if actor.id is null then raise sqlstate '42501' using message='Войдите, чтобы просматривать торговые остатки'; end if;
  if method<>'GET' or body<>'{}'::jsonb or path !~ '^my/trade-availability/[0-9]+$' then raise sqlstate 'P0002' using message='Метод API не найден'; end if;
  state_value:=split_part(path,'/',3)::integer;
  if not exists(select 1 from fauxlore.state_profiles where state_id=state_value) then raise sqlstate 'P0002' using message='Государство не найдено'; end if;
  return jsonb_build_object('state_id',state_value,'resources',coalesce((
    select jsonb_agg(jsonb_build_object('name',r->>'name','available',greatest(0,fauxlore.trade_resource_surplus(state_value,r->>'name')))
      order by r->>'category',r->>'name')
    from fauxlore.economy_parameters ep cross join lateral jsonb_array_elements(ep.config->'resources') r
    where ep.singleton and coalesce((r->>'showInProduction')::boolean,true)
  ),'[]'::jsonb));
end $$;
revoke all on function fauxlore.trade_availability_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.trade_availability_api(text,text,jsonb,uuid) to authenticated;

do $$ declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('public.fauxlore_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:=$old$elsif path='my/trade-interzone' then return fauxlore.trade_interzone_api(path,method,body,request_id);$old$;
  new_fragment:=$new$elsif path ~ '^my/trade-availability/[0-9]+$' then return fauxlore.trade_availability_api(path,method,body,request_id); elsif path='my/trade-interzone' then return fauxlore.trade_interzone_api(path,method,body,request_id);$new$;
  if position(old_fragment in fn)=0 then raise exception 'Missing trade API route insertion point'; end if;
  execute replace(fn,old_fragment,new_fragment);

  fn:=replace(pg_get_functiondef('fauxlore.trade_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:=$old$'sender',sender.name,'recipient',recipient.name,$old$;
  new_fragment:=$new$'sender',sender.name,'recipient',recipient.name,'sender_state_id',case when ts.direction='forward' then ta.from_state_id else ta.to_state_id end,'recipient_state_id',case when ts.direction='forward' then ta.to_state_id else ta.from_state_id end,$new$;
  if position(old_fragment in fn)=0 then raise exception 'Missing settlement API fields'; end if;
  execute replace(fn,old_fragment,new_fragment);

  fn:=replace(pg_get_functiondef('fauxlore.trade_market_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:=$old$'resource_name',ms.resource_name,'buyer',buyer.name,'seller',seller.name,'quantity'$old$;
  new_fragment:=$new$'resource_name',ms.resource_name,'buyer',buyer.name,'seller',seller.name,'buyer_state_id',ms.buyer_state_id,'seller_state_id',ms.seller_state_id,'quantity'$new$;
  if position(old_fragment in fn)=0 then raise exception 'Missing market settlement API fields'; end if;
  execute replace(fn,old_fragment,new_fragment);

  fn:=replace(pg_get_functiondef('fauxlore.trade_interzone_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:=$old$'resource_name',x.resource_name,'buyer',buyer.name,'seller',seller.name,'distance'$old$;
  new_fragment:=$new$'resource_name',x.resource_name,'buyer',buyer.name,'seller',seller.name,'buyer_state_id',x.buyer_state_id,'seller_state_id',x.seller_state_id,'distance'$new$;
  if position(old_fragment in fn)=0 then raise exception 'Missing interzone settlement API fields'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $$;
notify pgrst,'reload schema';
