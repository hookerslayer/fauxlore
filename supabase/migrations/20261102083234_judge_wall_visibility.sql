do $migration$
declare fn text; marker text;
begin
 fn:=pg_get_functiondef('fauxlore.wall_api(text,jsonb)'::regprocedure);
 marker:=$old$'id',p.id,'body',p.body,'rich_body',p.rich_body$old$;
 if position(marker in fn)=0 then raise exception 'wall listing hook missing'; end if;
 fn:=replace(fn,marker,$new$'id',p.id,'can_verdict',case when actor.role='admin' then true else exists(select 1 from fauxlore.judge_assignments j where j.judge_id=actor.id and j.player_id=p.account_id and j.judge_id<>j.player_id and fauxlore.judge_can_review(actor.id,p.state_id)) end,'body',p.body,'rich_body',p.rich_body$new$);
 execute fn;
end $migration$;
notify pgrst,'reload schema';
