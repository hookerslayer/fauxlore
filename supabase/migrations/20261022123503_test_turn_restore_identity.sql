-- Several turn-mutated tables use GENERATED ALWAYS identities, so snapshot restore must opt in.
do $$
declare fn text; old_insert text; new_insert text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.test_turn_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_insert:='      else'||chr(10)||
        '        execute format(''insert into fauxlore.%I select * from jsonb_populate_recordset(null::fauxlore.%I,$1)'',t,t) using snap_row;'||chr(10)||
        '      end if;';
  new_insert:='      else'||chr(10)||
        '        if t in (''state_characters'',''state_succession_events'',''state_birth_events'',''state_budget_ledger'') then'||chr(10)||
        '          execute format(''insert into fauxlore.%I overriding system value select * from jsonb_populate_recordset(null::fauxlore.%I,$1)'',t,t) using snap_row;'||chr(10)||
        '        else'||chr(10)||
        '          execute format(''insert into fauxlore.%I select * from jsonb_populate_recordset(null::fauxlore.%I,$1)'',t,t) using snap_row;'||chr(10)||
        '        end if;'||chr(10)||
        '      end if;';
  if position(old_insert in fn)=0 then raise exception 'Could not locate dynamic snapshot insert'; end if;
  execute replace(fn,old_insert,new_insert);
end $$;
