-- Run after the reviewed migrations; every change is rolled back.
begin;
create temporary table test_review_calendar(year integer,turn integer) on commit drop;
create trigger review_loan_penalties before update on test_review_calendar
for each row execute function fauxlore.apply_estate_loan_turn_penalties();
do $$
declare admin_uid uuid; state_key integer; province_key integer;
  cal fauxlore.game_calendar; before_crown numeric; before_lender numeric; before_prestige numeric;
  before_loyalty numeric; loan_id bigint; answer jsonb; command_id uuid:=gen_random_uuid();
  old_race integer; old_religion integer; next_race integer; next_religion integer;
begin
  select auth_user_id into admin_uid from fauxlore.accounts where role='admin' and auth_user_id is not null limit 1;
  if admin_uid is null then raise exception 'Admin account unavailable'; end if;
  perform set_config('request.jwt.claim.sub',admin_uid::text,true);
  select * into cal from fauxlore.game_calendar where singleton=true;
  select sp.state_id,p.id into state_key,province_key
  from fauxlore.state_profiles sp
  join fauxlore.province_values v on v.layer='states' and v.category_id=sp.state_id
  join fauxlore.provinces p on p.id=v.province_id and p.kind='land'
  join fauxlore.state_treasuries t on t.state_id=sp.state_id and t.estate='Знать' and t.balance>=100
  where not p.has_capital_marker order by sp.state_id,p.id limit 1;
  if province_key is null then raise exception 'Review test fixture unavailable'; end if;
  if exists(select 1 from fauxlore.provinces where province_type='Территориальная') then
    raise exception 'Retired province type remains'; end if;
  answer:=public.fauxlore_api('admin/states/'||state_key||'/estate-tax-rates','GET','{}'::jsonb,null);
  if jsonb_array_length(answer->'groups')<>4 then raise exception 'Four estate rates not available'; end if;
  select balance into before_crown from fauxlore.state_treasuries where state_id=state_key and estate='Корона';
  select balance into before_lender from fauxlore.state_treasuries where state_id=state_key and estate='Знать';
  answer:=public.fauxlore_api('admin/states/'||state_key||'/loans/borrow','POST',
    '{"lender":"Знать","amount":100}'::jsonb,gen_random_uuid());
  loan_id:=(answer->>'id')::bigint;
  if (select balance from fauxlore.state_treasuries where state_id=state_key and estate='Корона')<>before_crown+100
    or (select balance from fauxlore.state_treasuries where state_id=state_key and estate='Знать')<>before_lender-100
    or (select total_due from fauxlore.state_estate_loans where id=loan_id)<>105 then
    raise exception 'Loan did not conserve principal or calculate 5 percent'; end if;
  answer:=public.fauxlore_api('admin/states/'||state_key||'/loans/'||loan_id||'/repay','POST',
    '{"amount":105}'::jsonb,gen_random_uuid());
  if (answer->>'remaining')::numeric<>0
    or (select balance from fauxlore.state_treasuries where state_id=state_key and estate='Корона')<>before_crown-5
    or (select balance from fauxlore.state_treasuries where state_id=state_key and estate='Знать')<>before_lender+5 then
    raise exception 'Loan repayment did not transfer interest'; end if;
  answer:=public.fauxlore_api('admin/states/'||state_key||'/transit-toll','POST',
    '{"rate":0}'::jsonb,gen_random_uuid());
  if (answer->>'rate')::numeric<>0 or
    (select transit_toll_rate from fauxlore.state_trade_policies where state_id=state_key)<>0 then
    raise exception 'Transit toll was not disabled'; end if;
  answer:=public.fauxlore_api('admin/states/'||state_key||'/loans/borrow','POST',
    '{"lender":"Знать","amount":100}'::jsonb,gen_random_uuid());
  loan_id:=(answer->>'id')::bigint;
  update fauxlore.state_estate_loans set due_turn=cal.turn+1 where id=loan_id;
  update fauxlore.state_treasuries set balance=-10 where state_id=state_key and estate='Корона';
  select prestige into before_prestige from fauxlore.state_profiles where state_id=state_key;
  select loyalty into before_loyalty from fauxlore.state_group_politics
    where state_id=state_key and group_type='estate' and group_key='Знать';
  insert into test_review_calendar(year,turn) values(cal.year,cal.turn);
  update test_review_calendar set turn=turn+1;
  if (select prestige from fauxlore.state_profiles where state_id=state_key)<>before_prestige-2
    or (select loyalty from fauxlore.state_group_politics
      where state_id=state_key and group_type='estate' and group_key='Знать')<>greatest(0,before_loyalty-.05)
    or not (select late_penalty_applied from fauxlore.state_estate_loans where id=loan_id) then
    raise exception 'Negative treasury or overdue loan penalty failed'; end if;
  select official_race_id,official_religion_id into old_race,old_religion
    from fauxlore.state_profiles where state_id=state_key;
  select id into next_race from fauxlore.map_categories where layer='races' and id<>old_race order by id limit 1;
  select id into next_religion from fauxlore.map_categories where layer='religions' and id<>old_religion order by id limit 1;
  perform fauxlore.apply_ruler_change_effects(state_key,next_race,next_religion);
  if not exists(select 1 from fauxlore.state_profiles where state_id=state_key
    and official_race_id=next_race and official_religion_id=next_religion)
    or fauxlore.group_status_loyalty_modifier(state_key,'race',old_race)<>.05
    or fauxlore.group_status_loyalty_modifier(state_key,'religion',old_religion)<>.05 then
    raise exception 'Succession did not promote new groups and recognize old ones'; end if;
end $$;
select 'Four estate rates, loan transfers, overdue penalty, transit policy and succession passed' result;
rollback;
