do $migration$
declare fn text; marker text;
begin
 fn:=replace(pg_get_functiondef('fauxlore.process_province_assimilation()'::regprocedure),chr(13),'');
 marker:=$old$      if group_kind='race' then update fauxlore.provinces set race_assimilation_modifier_applied=old_modifier where id=province_row.id;
      else update fauxlore.provinces set religion_assimilation_modifier_applied=old_modifier where id=province_row.id; end if;$old$;
 marker:=replace(marker,chr(13),'');
 if position(marker in fn)=0 then raise exception 'assimilation modifier update hook missing';end if;
 fn:=replace(fn,marker,$new$      if group_kind='race' and old_modifier is distinct from province_row.race_assimilation_modifier_applied then
        update fauxlore.provinces set race_assimilation_modifier_applied=old_modifier where id=province_row.id;
      elsif group_kind='religion' and old_modifier is distinct from province_row.religion_assimilation_modifier_applied then
        update fauxlore.provinces set religion_assimilation_modifier_applied=old_modifier where id=province_row.id;
      end if;$new$);execute fn;
end $migration$;
