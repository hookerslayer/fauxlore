-- Apply the same access rules to fleets and treaty decisions as to the UI.
do $$ declare fn text; old_fragment text; new_fragment text; begin
 fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
 old_fragment:='where pv.category_id=sid or p.kind=''sea''';
 new_fragment:='where pv.category_id=sid or p.kind=''sea'' or (is_admin and p.kind=''land'')';
 if position(old_fragment in fn)=0 then raise exception 'Military province snapshot marker missing'; end if;
 fn:=replace(fn,old_fragment,new_fragment);
 old_fragment:='if not exists(select 1 from fauxlore.map_markers m where m.province_id=province_key and m.type=''port'') then';
 new_fragment:='if not exists(select 1 from fauxlore.map_markers m join fauxlore.map_adjacency a on a.singleton
      join lateral jsonb_array_elements_text(a.neighbors->m.province_id::text) n(value) on true
      join fauxlore.province_values v on v.province_id=n.value::integer and v.layer=''states'' and v.category_id=sid
      where m.province_id=province_key and m.type=''port'') then';
 if position(old_fragment in fn)=0 then raise exception 'Naval hiring marker missing'; end if;
 fn:=replace(fn,old_fragment,new_fragment);
 old_fragment:='if payload->>''decision''=''reject'' then';
 new_fragment:='if request_row.status=''accepted'' and (request_row.kind<>''passage'' or payload->>''decision''<>''end'') then
    raise sqlstate ''22023'' using message=''Договор уже действует''; end if;
  if payload->>''decision''=''reject'' then';
 if position(old_fragment in fn)=0 then raise exception 'Military decision marker missing'; end if;
 fn:=replace(fn,old_fragment,new_fragment);
 execute fn;
end $$;

create table if not exists fauxlore.military_mercenary_loyalty (
 state_id integer primary key references fauxlore.state_profiles(state_id) on delete cascade,
 remaining numeric(6,3) not null default 0 check(remaining>=0)
);
alter table fauxlore.military_mercenary_loyalty enable row level security;
revoke all on fauxlore.military_mercenary_loyalty from public,anon,authenticated;
do $$ declare fn text; old_fragment text; new_fragment text; begin
 fn:=pg_get_functiondef('fauxlore.charge_army_upkeep_before_turn()'::regprocedure);
 old_fragment:='update fauxlore.state_group_politics set loyalty=greatest(0,loyalty-.05*unpaid_mercenaries),
      recovery_target=least(1,coalesce(recovery_target,loyalty)+.005*unpaid_mercenaries)';
 new_fragment:='insert into fauxlore.military_mercenary_loyalty(state_id,remaining) values(state_row.state_id,.05*unpaid_mercenaries)
      on conflict(state_id) do update set remaining=fauxlore.military_mercenary_loyalty.remaining+excluded.remaining;
    update fauxlore.state_group_politics set loyalty=greatest(0,loyalty-.05*unpaid_mercenaries)';
 if position(old_fragment in fn)=0 then raise exception 'Mercenary loyalty marker missing'; end if;
 execute replace(fn,old_fragment,new_fragment);
 fn:=pg_get_functiondef('fauxlore.military_finish_turn()'::regprocedure);
 old_fragment:=' for state_row in select state_id from fauxlore.state_profiles order by state_id loop';
 new_fragment:=' for state_row in select state_id from fauxlore.state_profiles order by state_id loop
   update fauxlore.state_group_politics gp set loyalty=least(1,gp.loyalty+least(.005,ml.remaining))
     from fauxlore.military_mercenary_loyalty ml where ml.state_id=state_row.state_id and gp.state_id=ml.state_id
       and gp.group_type=''estate'' and gp.group_key=''Горожане'' and ml.remaining>0;
   update fauxlore.military_mercenary_loyalty set remaining=greatest(0,remaining-.005)
     where state_id=state_row.state_id and remaining>0;';
 if position(old_fragment in fn)=0 then raise exception 'Mercenary recovery marker missing'; end if;
 execute replace(fn,old_fragment,new_fragment);
end $$;
