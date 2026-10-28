create or replace function fauxlore.wall_verdict_many(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; target_ids integer[]; sid integer; first_id integer; expense_g integer; expense_op integer; item jsonb; body_value text; names text; result_value jsonb;
begin
  actor:=fauxlore.current_account();
  if actor.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if jsonb_typeof(payload->'state_ids')<>'array' or jsonb_array_length(payload->'state_ids') not between 1 and 10 then raise sqlstate '22023' using message='Выберите от одного до десяти государств'; end if;
  select array_agg(distinct value::integer order by value::integer) into target_ids from jsonb_array_elements_text(payload->'state_ids') value;
  if cardinality(target_ids)<>jsonb_array_length(payload->'state_ids') then raise sqlstate '22023' using message='Государства в вердикте не должны повторяться'; end if;
  if (select count(*) from fauxlore.state_profiles where state_id=any(target_ids))<>cardinality(target_ids) then raise sqlstate 'P0002' using message='Государство не найдено'; end if;
  expense_g:=coalesce((payload->>'treasury_expense')::integer,0);expense_op:=coalesce((payload->>'prestige_expense')::integer,0);
  if expense_g<0 or expense_op<0 then raise sqlstate '22023' using message='Расходы не могут быть отрицательными'; end if;
  select string_agg(c.name,', ' order by c.name) into names from fauxlore.map_categories c where c.layer='states' and c.id=any(target_ids);
  body_value:=btrim(coalesce(payload->>'body',''));
  if length(body_value) not between 1 and 9000 then raise sqlstate '22023' using message='Укажите текст вердикта'; end if;
  first_id:=target_ids[1];
  result_value:=fauxlore.wall_api('verdict',payload||jsonb_build_object('state_id',first_id,'body',body_value||E'\nГосударства: '||names));
  foreach sid in array target_ids loop
    if sid=first_id then continue; end if;
    if expense_g>0 then
      update fauxlore.state_treasuries set balance=balance-expense_g where state_id=sid and estate='Корона' and balance>=expense_g;
      if not found then raise sqlstate '22023' using message='Недостаточно средств в Казне одного из государств'; end if;
      update fauxlore.state_profiles set treasury=treasury-expense_g where state_id=sid;
    end if;
    if expense_op>0 then
      update fauxlore.state_profiles set prestige=prestige-expense_op where state_id=sid and prestige>=expense_op;
      if not found then raise sqlstate '22023' using message='Недостаточно ОП у одного из государств'; end if;
    end if;
    for item in select value from jsonb_array_elements(coalesce(payload->'modifiers','[]'::jsonb)) value loop
      perform fauxlore.admin_modifiers_api('assign',item||jsonb_build_object('state_id',sid,'target_kind','state','province_id',null));
    end loop;
    insert into fauxlore.notifications(account_id,kind,title,message) select account_id,'wall_verdict','Вердикт на пост','Администратор вынес вердикт по посту №'||(payload->>'post_id')||'.' from fauxlore.account_states where layer='states' and state_id=sid;
  end loop;
  return result_value||jsonb_build_object('state_ids',to_jsonb(target_ids));
end $function$;
revoke all on function fauxlore.wall_verdict_many(jsonb) from public,anon,authenticated;
grant execute on function fauxlore.wall_verdict_many(jsonb) to authenticated;
create or replace function public.wall_verdict_many(payload jsonb)
returns jsonb language sql security invoker set search_path=pg_catalog,fauxlore as $$select fauxlore.wall_verdict_many(payload)$$;
revoke all on function public.wall_verdict_many(jsonb) from public,anon;
grant execute on function public.wall_verdict_many(jsonb) to authenticated;
notify pgrst,'reload schema';
