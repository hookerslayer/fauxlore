do $migration$
declare fn text; marker text;
begin
 fn:=pg_get_functiondef('public.judge_assignments_api(text,jsonb)'::regprocedure);
 marker:=$old$   'assignments',coalesce((select jsonb_agg($old$;
 if position(marker in fn)=0 then raise exception 'admin snapshot hook missing'; end if;
 fn:=replace(fn,marker,$new$   'users',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'nickname',a.nickname,'role',a.role,'states',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name) order by c.name,c.id) from fauxlore.account_states ast join fauxlore.map_categories c on c.layer='states' and c.id=ast.state_id where ast.layer='states' and ast.account_id=a.id),'[]'::jsonb)) order by a.nickname,a.id) from fauxlore.accounts a),'[]'::jsonb),
   'assignments',coalesce((select jsonb_agg($new$);execute fn;
end $migration$;
notify pgrst,'reload schema';
