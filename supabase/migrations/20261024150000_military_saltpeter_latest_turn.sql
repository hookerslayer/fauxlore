do $$ declare fn text; old_fragment text; new_fragment text; begin
 fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
 old_fragment:='(r.year,r.turn)=(select year,turn from fauxlore.game_calendar where singleton)';
 new_fragment:='(r.year,r.turn)=(select year,turn from fauxlore.trade_state_resource_turns order by year desc,turn desc limit 1)';
 if position(old_fragment in fn)=0 then raise exception 'Saltpeter turn marker missing'; end if;
 execute replace(fn,old_fragment,new_fragment);
end $$;
