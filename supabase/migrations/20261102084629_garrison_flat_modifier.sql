alter table fauxlore.permanent_modifier_definitions drop constraint permanent_modifier_definitions_source_kind_check;
alter table fauxlore.permanent_modifier_definitions add constraint permanent_modifier_definitions_source_kind_check check (source_kind in ('authority','structure','economy','military','race','religion','constructor'));
insert into fauxlore.permanent_modifier_definitions(source_kind,source_key,modifier_key,effect,value,unit,scope,condition_text) values('constructor','Назначение','garrison_limit_flat','Лимит гарнизонов',0,'ед.','Государство','');
do $migration$
declare fn text; marker text; replacement text;
begin
 fn:=pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure);
 marker:=$old$'garrison_upkeep','garrison_limit','militia_coefficient'$old$;
 replacement:=$new$'garrison_upkeep','garrison_limit','garrison_limit_flat','militia_coefficient'$new$;
 if position(marker in fn)=0 then raise exception 'garrison scope hook missing'; end if; execute replace(fn,marker,replacement);
 fn:=pg_get_functiondef('fauxlore.garrison_capacity(integer)'::regprocedure);
 marker:=$old$select floor(greatest(0,base.value)*(1+fauxlore.state_permanent_modifier_total(
  base.state_id,array['garrison_limit'],province_key,null)))::integer$old$;
 replacement:=$new$select floor(greatest(0,base.value*(1+fauxlore.state_permanent_modifier_total(
  base.state_id,array['garrison_limit'],province_key,null))+fauxlore.state_permanent_modifier_total(base.state_id,array['garrison_limit_flat'],province_key,null)))::integer$new$;
 marker:=replace(marker,chr(13),'');replacement:=replace(replacement,chr(13),'');
 if position(marker in fn)=0 then raise exception 'garrison capacity hook missing'; end if; execute replace(fn,marker,replacement);
end $migration$;
notify pgrst,'reload schema';
