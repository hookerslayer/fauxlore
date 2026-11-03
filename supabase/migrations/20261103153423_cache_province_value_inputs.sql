-- Reuse exactly the same stable province-control and crime inputs.
-- Run in a transaction so the parity check can roll back the replacement.
create temporary table province_value_baseline on commit drop as
select p.id province_id,v.category_id state_id,fauxlore.province_value_for_state(p.id,v.category_id) value
from fauxlore.provinces p join fauxlore.province_values v on v.province_id=p.id and v.layer='states'
where p.kind='land';
do $migration$
declare fn text; old text; replacement text; n integer;
begin
 fn:=pg_get_functiondef('fauxlore.province_value_for_state(integer,integer)'::regprocedure);
 old:='share numeric:=0; control_value numeric; population numeric;';
 if position(old in fn)=0 then raise exception 'province value declaration hook missing'; end if;
 fn:=replace(fn,old,'share numeric:=0; control_value numeric; control_percent numeric; population numeric;');
 old:='control_value:=fauxlore.effective_province_control(p.id,target_state)::numeric/100;';
 if position(old in fn)=0 then raise exception 'province value control calculation hook missing'; end if;
 fn:=replace(fn,old,'control_percent:=fauxlore.effective_province_control(p.id,target_state)::numeric; control_value:=control_percent/100;');
 old:='greatest(0,least(100,fauxlore.effective_province_control(p.id,target_state)))';
 if position(old in fn)=0 then raise exception 'province value control use hook missing'; end if;
 fn:=replace(fn,old,'greatest(0,least(100,control_percent))');
 old:=$old$coalesce((select fauxlore.effective_social_rate(target_state,'crime',crime) from fauxlore.state_profiles where state_id=target_state),.2)$old$;
 n:=(length(fn)-length(replace(fn,old,'')))/length(old);
 if n<>1 then raise exception 'province value crime hook missing or ambiguous'; end if;
 replacement:=$new$case when owner_state=target_state then crime_rate else coalesce((select fauxlore.effective_social_rate(target_state,'crime',crime) from fauxlore.state_profiles where state_id=target_state),.2) end$new$;
 execute replace(fn,old,replacement);
end $migration$;
do $verify$ begin
 if exists(select 1 from province_value_baseline b where b.value is distinct from fauxlore.province_value_for_state(b.province_id,b.state_id)) then raise exception 'province value parity check failed'; end if;
end $verify$;
notify pgrst,'reload schema';
