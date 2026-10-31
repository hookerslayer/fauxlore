-- Reuse server-calculated recruitment and calculate each unit cost factor once.
-- Snapshot comparison is performed in the same repeatable-read transaction.
set transaction isolation level repeatable read;
set local statement_timeout = '90s';
create temporary table military_snapshot_before on commit drop as
with administrator as materialized (
  select set_config('request.jwt.claim.sub',a.auth_user_id::text,true)
  from fauxlore.accounts a join auth.users u on u.id=a.auth_user_id and u.email_confirmed_at is not null
  join auth.identities i on i.user_id=u.id and i.provider='google' and i.identity_data->>'email_verified'='true'
  where a.role='admin' and coalesce(i.identity_data->>'sub','')<>'' limit 1
)
select s.state_id,public.military_api('snapshot',s.state_id,'{}'::jsonb) snapshot
from fauxlore.state_profiles s cross join administrator;

do $migration$
declare definition text; old_part text; new_part text;
begin
 definition:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
 old_part:=$old$'recruitment',fauxlore.state_recruitment(sid),$old$;
 if position(old_part in definition)=0 then raise exception 'Military recruitment marker missing'; end if;
 new_part:=$new$'recruitment',case when indicator_snapshot ? 'recruit_growth' and indicator_snapshot ? 'recruit_limit' then jsonb_build_object('recruit_growth',indicator_snapshot->'recruit_growth','recruit_limit',indicator_snapshot->'recruit_limit') else fauxlore.state_recruitment(sid) end,$new$;
 definition:=replace(definition,old_part,new_part);
 old_part:=$old$'catalog',(select coalesce(jsonb_agg(to_jsonb(u)||jsonb_build_object('hire_factor',fauxlore.military_unit_cost_factor(sid,u.id,'hire'),'upkeep_factor',fauxlore.military_unit_cost_factor(sid,u.id,'upkeep'),'hire_price',floor(u.hire_cost*fauxlore.military_unit_cost_factor(sid,u.id,'hire')),'upkeep_price',floor(u.upkeep*fauxlore.military_unit_cost_factor(sid,u.id,'upkeep'))) order by u.domain,u.id),'[]'::jsonb) from fauxlore.military_unit_catalog u where u.active and (u.state_id is null or u.state_id=sid)),$old$;
 if position(old_part in definition)=0 then raise exception 'Military catalog marker missing'; end if;
 new_part:=$new$'catalog',(with factors as materialized (select u.*,fauxlore.military_unit_cost_factor(sid,u.id,'hire') as _hire_factor,fauxlore.military_unit_cost_factor(sid,u.id,'upkeep') as _upkeep_factor from fauxlore.military_unit_catalog u where u.active and (u.state_id is null or u.state_id=sid)) select coalesce(jsonb_agg((to_jsonb(u)-'_hire_factor'-'_upkeep_factor')||jsonb_build_object('hire_factor',u._hire_factor,'upkeep_factor',u._upkeep_factor,'hire_price',floor(u.hire_cost*u._hire_factor),'upkeep_price',floor(u.upkeep*u._upkeep_factor)) order by u.domain,u.id),'[]'::jsonb) from factors u),$new$;
 definition:=replace(definition,old_part,new_part);
 execute definition;
end
$migration$;

do $verify$
declare mismatches integer;
begin
 select count(*) into mismatches from military_snapshot_before b
 where b.snapshot is distinct from public.military_api('snapshot',b.state_id,'{}'::jsonb);
 if mismatches<>0 then raise exception 'Military snapshot parity failed for % states',mismatches; end if;
end
$verify$;
notify pgrst,'reload schema';
