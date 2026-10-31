do $migration$ declare fn text; old_text text; new_text text; begin
  fn:=pg_get_functiondef('fauxlore.state_permanent_modifier_total(integer,text[],integer,text)'::regprocedure);
  old_text:='if row_value->>''target_trade_zone_id'' is not null and target_province is not null and not exists(';
  new_text:='if row_value->>''target_trade_zone_id'' is not null and (target_province is null or not exists(';
  if position(old_text in fn)=0 then raise exception 'Trade zone modifier guard not found'; end if;
  fn:=replace(fn,old_text,new_text);
  old_text:='and z.category_id=(row_value->>''target_trade_zone_id'')::integer) then continue; end if;';
  new_text:='and z.category_id=(row_value->>''target_trade_zone_id'')::integer)) then continue; end if;';
  if position(old_text in fn)=0 then raise exception 'Trade zone modifier guard end not found'; end if;
  execute replace(fn,old_text,new_text);
end $migration$;
notify pgrst,'reload schema';
