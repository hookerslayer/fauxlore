-- Keep the SQL indicators in sync with the server-side province projection.
do $migration$
declare
  fn text;
  old_fragment text;
  new_fragment text;
begin
  fn:=pg_get_functiondef('fauxlore.state_indicators_before_urbanization(integer)'::regprocedure);
  old_fragment:=$old$select *,coalesce(adjusted_weight/nullif(sum(adjusted_weight) over(),0),0) influence from (select estates.*,weight*case when name='Крестьяне' then greatest(0,1+fauxlore.state_permanent_modifier_total(target_state,array['peasant_influence'],null,null)) else 1 end adjusted_weight from estates) weighted$old$;
  new_fragment:=$new$select *,case when privileged_weight>0 and powerless_weight>total_weight*.1 then
    case when status='Бесправное' then .1*adjusted_weight/nullif(powerless_weight,0)
      else .9*adjusted_weight/nullif(privileged_weight,0) end
    else coalesce(adjusted_weight/nullif(total_weight,0),0) end influence
  from (select weighted.*,sum(adjusted_weight) over() total_weight,
    sum(adjusted_weight) filter(where status='Бесправное') over() powerless_weight,
    coalesce(sum(adjusted_weight) filter(where status is distinct from 'Бесправное') over(),0) privileged_weight
    from (select estates.*,weight*case when name='Крестьяне' then greatest(0,1+fauxlore.state_permanent_modifier_total(target_state,array['peasant_influence'],null,null)) else 1 end adjusted_weight from estates) weighted) totals$new$;
  if position(old_fragment in fn)=0 then raise exception 'estate influence source differs from expected'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:=$old$influence-case status when 'Ключевое' then .5 when 'Значимое' then .35 else 0 end$old$;
  new_fragment:=$new$influence-case status when 'Ключевое' then .4 when 'Значимое' then .2 else 0 end$new$;
  if position(old_fragment in fn)=0 then raise exception 'estate ambition source differs from expected'; end if;
  execute replace(fn,old_fragment,new_fragment);

  fn:=pg_get_functiondef('fauxlore.state_permanent_modifier_total(integer,text[],integer,text)'::regprocedure);
  old_fragment:=$old$group_key='Знать'),0)<=60$old$;
  if position(old_fragment in fn)=0 then raise exception 'nobility loyalty threshold differs from expected'; end if;
  fn:=replace(fn,old_fragment,$new$group_key='Знать'),0)<=.60$new$);
  old_fragment:=$old$status='Ключевое' and loyalty<=60$old$;
  if position(old_fragment in fn)=0 then raise exception 'key estate loyalty threshold differs from expected'; end if;
  execute replace(fn,old_fragment,$new$status='Ключевое' and loyalty<=.60$new$);
end
$migration$;
