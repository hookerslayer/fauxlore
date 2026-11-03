-- Reuse identical stable province and state inputs within recruitment.
-- Apply inside a transaction so parity failure rolls back the function replacement.
create temporary table recruitment_baseline on commit drop as
select state_id,fauxlore.state_recruitment(state_id) value from fauxlore.state_profiles;
do $migration$
declare fn text; old text; replacement text; n integer;
begin
 fn:=pg_get_functiondef('fauxlore.state_recruitment(integer)'::regprocedure);
 old:='fauxlore.effective_province_control(p.id,target_state)';
 n:=(length(fn)-length(replace(fn,old,'')))/length(old);
 if n<>2 then raise exception 'recruitment control hook missing or ambiguous'; end if;
 fn:=replace(fn,old,'p.cached_control');
 old:=$old$fauxlore.group_status_effect(target_state,'race',p.race_id,'recruit')$old$;
 n:=(length(fn)-length(replace(fn,old,'')))/length(old);
 if n<>2 then raise exception 'recruitment race hook missing or ambiguous'; end if;
 fn:=replace(fn,old,'p.cached_race');
 old:=$old$fauxlore.group_status_effect(target_state,'religion',(select category_id from fauxlore.province_values where province_id=p.id and layer='religions'),'recruit')$old$;
 n:=(length(fn)-length(replace(fn,old,'')))/length(old);
 if n<>2 then raise exception 'recruitment religion hook missing or ambiguous'; end if;
 fn:=replace(fn,old,'p.cached_religion');
 old:=$old$fauxlore.effective_social_rate(target_state,'crime',sp.crime)$old$;
 if position(old in fn)=0 then raise exception 'recruitment crime hook missing'; end if;
 fn:=replace(fn,old,'(select crime from state_crime)');
 old:='left join provinces p on true';
 if position(old in fn)=0 then raise exception 'recruitment provinces hook missing'; end if;
 fn:=replace(fn,old,'left join province_inputs p on true');
 old:=E')\nselect jsonb_build_object(';
 if position(old in fn)=0 then raise exception 'recruitment CTE hook missing'; end if;
 replacement:=$sql$), province_inputs as materialized (
  select p.*,fauxlore.effective_province_control(p.id,target_state) cached_control,
    fauxlore.group_status_effect(target_state,'race',p.race_id,'recruit') cached_race,
    fauxlore.group_status_effect(target_state,'religion',(select category_id from fauxlore.province_values where province_id=p.id and layer='religions'),'recruit') cached_religion
  from provinces p
), state_crime as materialized (
  select fauxlore.effective_social_rate(target_state,'crime',sp.crime) crime from fauxlore.state_profiles sp where sp.state_id=target_state
)
select jsonb_build_object($sql$;
 execute replace(fn,old,replacement);
end $migration$;
do $verify$ begin
 if exists(select 1 from recruitment_baseline b where b.value is distinct from fauxlore.state_recruitment(b.state_id)) then raise exception 'recruitment parity check failed'; end if;
end $verify$;
notify pgrst,'reload schema';
