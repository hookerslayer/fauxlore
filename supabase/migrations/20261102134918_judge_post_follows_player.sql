do $migration$
declare fn text; marker text;
begin
 fn:=pg_get_functiondef('fauxlore.wall_api(text,jsonb)'::regprocedure);
 marker:=$old$j.judge_id<>j.player_id and fauxlore.judge_can_review(actor.id,p.state_id)$old$;
 if position(marker in fn)=0 then raise exception 'judge wall visibility hook missing';end if;
 fn:=replace(fn,marker,$new$j.judge_id<>j.player_id and exists(select 1 from fauxlore.account_states current_state where current_state.account_id=p.account_id and fauxlore.judge_can_review(actor.id,current_state.state_id))$new$);execute fn;
end $migration$;
