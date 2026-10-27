-- One payer per provincial garrison site. Existing sites stay Crown-funded.
do $$ begin
 if exists(select 1 from fauxlore.turn_test_snapshot where singleton=true) then
   raise exception 'Rollback the active test turn before adding garrison sponsorship'; end if;
end $$;
alter table fauxlore.garrison_sites add column sponsor_estate text not null default 'Корона'
  check (sponsor_estate in ('Корона','Знать','Духовенство','Горожане','Крестьяне'));
alter table fauxlore.garrison_charges add column payers jsonb not null default '{}'::jsonb;

create or replace function fauxlore.garrison_site_upkeep(province_key integer)
returns numeric language sql stable security definer set search_path='' as $function$
  select coalesce((select sum(round(u.quantity*c.upkeep*.4,2))
    from fauxlore.garrison_units u join fauxlore.military_unit_catalog c on c.id=u.unit_id
    where u.province_id=province_key),0)
    +greatest(0,(case g.fort_level when 1 then 100 when 2 then 200 when 3 then 300 when 4 then 400 else 0 end)
      -case when g.free_fort then 300 else 0 end)
    +greatest(0,(case g.wall_level when 1 then 300 when 2 then 500 when 3 then 700 else 0 end)
      -case when g.free_wall then 300 else 0 end)
  from fauxlore.garrison_sites g where g.province_id=province_key
$function$;
revoke all on function fauxlore.garrison_site_upkeep(integer) from public,anon,authenticated;

create or replace function fauxlore.charge_garrison_before_turn()
returns trigger language plpgsql security definer set search_path='' as $function$
declare state_row record; payer_row record; troop_cost numeric; fort_cost numeric;
  total_cost numeric; closing_balance numeric; payer_costs jsonb;
begin
 if new.year=old.year and new.turn=old.turn then return new; end if;
 for state_row in select state_id from fauxlore.state_profiles order by state_id loop
   select coalesce(sum(round(u.quantity*c.upkeep*.4,2)),0) into troop_cost
     from fauxlore.garrison_units u join fauxlore.garrison_sites g on g.province_id=u.province_id
     join fauxlore.military_unit_catalog c on c.id=u.unit_id where g.state_id=state_row.state_id;
   total_cost:=fauxlore.garrison_upkeep(state_row.state_id);fort_cost:=total_cost-troop_cost;
   if total_cost<=0 then continue; end if;
   payer_costs:='{}'::jsonb;
   for payer_row in select g.sponsor_estate payer,sum(fauxlore.garrison_site_upkeep(g.province_id)) amount
     from fauxlore.garrison_sites g where g.state_id=state_row.state_id
     group by g.sponsor_estate order by g.sponsor_estate loop
     if payer_row.amount<=0 then continue; end if;
     update fauxlore.state_treasuries set balance=balance-payer_row.amount,updated_at=now()
       where state_id=state_row.state_id and estate=payer_row.payer;
     if not found then raise exception 'Missing treasury for garrison sponsor %',payer_row.payer; end if;
     payer_costs:=payer_costs||jsonb_build_object(payer_row.payer,payer_row.amount);
   end loop;
   insert into fauxlore.garrison_charges(state_id,year,turn,troops,fortifications,payers)
     values(state_row.state_id,old.year,old.turn,troop_cost,fort_cost,payer_costs);
   select coalesce(sum(balance),0) into closing_balance from fauxlore.state_treasuries where state_id=state_row.state_id;
   update fauxlore.state_profiles set treasury=closing_balance where state_id=state_row.state_id;
   update fauxlore.turn_economy_reports set report=(select jsonb_agg(case when (entry.value->>'id')::integer=state_row.state_id then
      entry.value||jsonb_build_object('garrison_upkeep',troop_cost,'fortification_upkeep',fort_cost,
       'garrison_payers',payer_costs,'army_upkeep',coalesce((entry.value->>'army_upkeep')::numeric,0)+total_cost,
       'army_upkeep_paid',coalesce((entry.value->>'army_upkeep_paid')::numeric,0)+total_cost,
       'closing_treasury',closing_balance,'tax_buckets',(select jsonb_object_agg(estate,balance)
         from fauxlore.state_treasuries where state_id=state_row.state_id))
      else entry.value end order by entry.ord) from jsonb_array_elements(report) with ordinality entry(value,ord))
     where year=old.year and turn=old.turn;
 end loop;
 return new;
end $function$;
revoke all on function fauxlore.charge_garrison_before_turn() from public,anon,authenticated;

-- Keep the public garrison API's existing ownership, capacity, recruit and
-- neutral-fort checks. Only extend its payer choice and payment source.
do $$
declare definition text; old_text text; new_text text;
begin
 definition:=pg_get_functiondef('public.garrison_api(text,integer,integer,jsonb)'::regprocedure);
 old_text:=' if action not in (''hire'',''build'') then raise sqlstate ''22023'' using message=''Неизвестное действие гарнизона''; end if;';
 new_text:=$patch$
 if action='sponsor' then
   select * into site from fauxlore.garrison_sites where province_id=province_key and state_id=sid for update;
   if not found or not exists(select 1 from fauxlore.province_values
     where province_id=province_key and layer='states' and category_id=sid) then
     raise sqlstate '42501' using message='Плательщика можно выбрать только для своего гарнизона'; end if;
   project_kind:=payload->>'estate';
   if project_kind is null or project_kind not in ('Корона','Знать','Духовенство','Горожане','Крестьяне') then
     raise sqlstate '22023' using message='Выберите казну плательщика'; end if;
   if project_kind<>'Корона' then
     if fauxlore.estate_status_for(sid,project_kind)='Бесправное' then
       raise sqlstate '22023' using message='Бесправное сословие не может финансировать гарнизон'; end if;
     select balance into balance_value from fauxlore.state_treasuries
       where state_id=sid and estate=project_kind for update;
     if coalesce(balance_value,0)<2*fauxlore.garrison_site_upkeep(province_key) then
       raise sqlstate '22023' using message='У сословия нет резерва на два хода содержания'; end if;
   end if;
   update fauxlore.garrison_sites set sponsor_estate=project_kind where province_id=province_key;
   return jsonb_build_object('sponsor',project_kind,'upkeep',fauxlore.garrison_site_upkeep(province_key));
 end if;
 if action not in ('hire','build') then raise sqlstate '22023' using message='Неизвестное действие гарнизона'; end if;$patch$;
 if position(old_text in definition)=0 then raise exception 'Garrison action marker missing'; end if;
 definition:=replace(definition,old_text,new_text);
 old_text:='''fort_level'',coalesce(g.fort_level,0),''wall_level'',coalesce(g.wall_level,0),''free_fort''';
 new_text:='''fort_level'',coalesce(g.fort_level,0),''wall_level'',coalesce(g.wall_level,0),''sponsor'',coalesce(g.sponsor_estate,''Корона''),''free_fort''';
 if position(old_text in definition)=0 then raise exception 'Garrison snapshot marker missing'; end if;
 definition:=replace(definition,old_text,new_text);
 old_text:='and estate=''Корона'' for update;';
 if (length(definition)-length(replace(definition,old_text,'')))/length(old_text)<>2 then
   raise exception 'Garrison payment lookup marker count changed'; end if;
 definition:=replace(definition,old_text,'and estate=coalesce(site.sponsor_estate,''Корона'') for update;');
 old_text:='and estate=''Корона'';';
 if (length(definition)-length(replace(definition,old_text,'')))/length(old_text)<>2 then
   raise exception 'Garrison payment debit marker count changed'; end if;
 definition:=replace(definition,old_text,'and estate=coalesce(site.sponsor_estate,''Корона'');');
 definition:=replace(definition,'Недостаточно G в казне Короны','Недостаточно G в казне плательщика');
 execute definition;
end $$;

-- Keep a two-turn upkeep reserve out of the development investment budget.
do $$
declare definition text; old_text text; new_text text;
begin
 definition:=pg_get_functiondef('fauxlore.settle_estate_investments()'::regprocedure);
 old_text:='remaining_g:=floor(greatest(coalesce(estate_balance,0),0)*.20)::integer;';
 new_text:='remaining_g:=floor(greatest(coalesce(estate_balance,0)-2*coalesce((select sum(fauxlore.garrison_site_upkeep(g.province_id)) from fauxlore.garrison_sites g where g.state_id=state_row.state_id and g.sponsor_estate=estate_name),0),0)*.20)::integer;';
 if position(old_text in definition)=0 then raise exception 'Estate investment budget marker missing'; end if;
 execute replace(definition,old_text,new_text);
end $$;
do $$
declare definition text; old_text text; new_text text;
begin
 definition:=pg_get_functiondef('public.estate_investment_api(text,integer,jsonb)'::regprocedure);
 old_text:='floor(greatest(coalesce(t.balance,0),0)*.20)';
 new_text:='floor(greatest(coalesce(t.balance,0)-2*coalesce((select sum(fauxlore.garrison_site_upkeep(g.province_id)) from fauxlore.garrison_sites g where g.state_id=target_state and g.sponsor_estate=e.name),0),0)*.20)';
 if (length(definition)-length(replace(definition,old_text,'')))/length(old_text)<>2 then
   raise exception 'Estate budget API marker count changed'; end if;
 execute replace(definition,old_text,new_text);
end $$;
notify pgrst,'reload schema';
