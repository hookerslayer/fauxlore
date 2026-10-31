-- Reuse the same estate calculation for stability and conditional effects.
do $migration$
declare source text; prefix text; body text; start_pos integer; end_pos integer;
  old_nobility text; old_key text;
begin
  source:=pg_get_functiondef('fauxlore.state_indicators_before_urbanization(integer)'::regprocedure);
  start_pos:=position('with cfg as' in source);
  end_pos:=position('), estate_block as (' in source);
  if start_pos=0 or end_pos<=start_pos then raise exception 'Estate loyalty calculation changed'; end if;
  prefix:=substring(source from start_pos for end_pos-start_pos);
  execute 'create or replace function fauxlore.effective_estate_loyalties(target_state integer) returns table(name text, status text, effective_loyalty numeric, influence numeric) language sql stable security definer set search_path='''' as $body$'
    ||prefix||') select name,status,effective_loyalty,influence from loyalties $body$';
  execute 'revoke all on function fauxlore.effective_estate_loyalties(integer) from public,anon,authenticated';

  start_pos:=position('), loyalties as (' in source);
  end_pos:=position('), estate_block as (' in source);
  if start_pos=0 or end_pos<=start_pos then raise exception 'Estate loyalty CTE changed'; end if;
  source:=substring(source from 1 for start_pos-1)||'), loyalties as (select * from fauxlore.effective_estate_loyalties(target_state)'
    ||substring(source from end_pos);
  execute source;

  source:=pg_get_functiondef('fauxlore.state_permanent_modifier_total(integer,text[],integer,text)'::regprocedure);
  old_nobility:=$old$select loyalty from fauxlore.state_group_politics where state_id=target_state and group_type='estate' and group_key='Знать'$old$;
  old_key:=$old$not exists(select 1 from fauxlore.state_group_politics where state_id=target_state and group_type='estate' and status='Ключевое')
      or exists(select 1 from fauxlore.state_group_politics where state_id=target_state and group_type='estate' and status='Ключевое' and loyalty<=.60)$old$;
  if position(old_nobility in source)=0 or position(old_key in source)=0 then raise exception 'Loyalty conditions changed'; end if;
  source:=replace(source,old_nobility,$new$select effective_loyalty from fauxlore.effective_estate_loyalties(target_state) where name='Знать'$new$);
  source:=replace(source,old_key,$new$not exists(select 1 from fauxlore.effective_estate_loyalties(target_state) where status='Ключевое')
      or exists(select 1 from fauxlore.effective_estate_loyalties(target_state) where status='Ключевое' and effective_loyalty<=.60)$new$);
  execute source;
end
$migration$;
