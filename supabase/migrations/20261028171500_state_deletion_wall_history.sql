-- Keep published posts and verdicts when their state is removed. The state name
-- remains a historical attribution even after the live state record is gone.
alter table fauxlore.wall_posts add column state_name text;
alter table fauxlore.wall_verdicts add column state_name text;

update fauxlore.wall_posts p set state_name=c.name
from fauxlore.map_categories c
where c.layer='states' and c.id=p.state_id;
update fauxlore.wall_verdicts v set state_name=c.name
from fauxlore.map_categories c
where c.layer='states' and c.id=v.state_id;

create function fauxlore.remember_wall_state_name()
returns trigger language plpgsql security invoker set search_path='' as $function$
begin
  if new.state_id is not null then
    select c.name into new.state_name
    from fauxlore.map_categories c where c.layer='states' and c.id=new.state_id;
  end if;
  return new;
end $function$;
create trigger wall_posts_remember_state before insert or update of state_id
on fauxlore.wall_posts for each row execute function fauxlore.remember_wall_state_name();
create trigger wall_verdicts_remember_state before insert or update of state_id
on fauxlore.wall_verdicts for each row execute function fauxlore.remember_wall_state_name();

alter table fauxlore.wall_posts drop constraint wall_posts_state_id_fkey;
alter table fauxlore.wall_posts add constraint wall_posts_state_id_fkey
  foreign key (state_id) references fauxlore.state_profiles(state_id) on delete set null;
alter table fauxlore.wall_verdicts alter column state_id drop not null;
alter table fauxlore.wall_verdicts drop constraint wall_verdicts_state_id_fkey;
alter table fauxlore.wall_verdicts add constraint wall_verdicts_state_id_fkey
  foreign key (state_id) references fauxlore.state_profiles(state_id) on delete set null;

-- A state cannot leave half of a live diplomatic proposal behind. The admin
-- deletion RPC removes the whole proposal when any participant is deleted.
do $migration$
declare definition text;
  marker text := '  delete from fauxlore.state_profiles where state_id=state_value;';
  replacement text := '  delete from fauxlore.diplomatic_proposals dp where dp.proposer_state_id=state_value'
    || ' or exists(select 1 from fauxlore.diplomatic_proposal_participants pp'
    || ' where pp.proposal_id=dp.id and pp.state_id=state_value);' || chr(10) || marker;
begin
  definition:=pg_get_functiondef('fauxlore.game_state_api(text,text,jsonb,uuid)'::regprocedure);
  if position(marker in definition)=0 then raise exception 'State deletion hook missing'; end if;
  execute replace(definition,marker,replacement);
end $migration$;

-- Other state-owned records have no useful identity without either party.
alter table fauxlore.diplomatic_proposals drop constraint diplomatic_proposals_proposer_state_id_fkey;
alter table fauxlore.diplomatic_proposals add constraint diplomatic_proposals_proposer_state_id_fkey
  foreign key (proposer_state_id) references fauxlore.state_profiles(state_id) on delete cascade;
alter table fauxlore.diplomatic_proposal_participants drop constraint diplomatic_proposal_participants_state_id_fkey;
alter table fauxlore.diplomatic_proposal_participants add constraint diplomatic_proposal_participants_state_id_fkey
  foreign key (state_id) references fauxlore.state_profiles(state_id) on delete cascade;
alter table fauxlore.military_sieges drop constraint military_sieges_attacker_state_id_fkey;
alter table fauxlore.military_sieges add constraint military_sieges_attacker_state_id_fkey
  foreign key (attacker_state_id) references fauxlore.state_profiles(state_id) on delete cascade;
alter table fauxlore.military_sieges drop constraint military_sieges_defender_state_id_fkey;
alter table fauxlore.military_sieges add constraint military_sieges_defender_state_id_fkey
  foreign key (defender_state_id) references fauxlore.state_profiles(state_id) on delete cascade;
alter table fauxlore.trade_market_settlements drop constraint trade_market_settlements_buyer_state_id_fkey;
alter table fauxlore.trade_market_settlements add constraint trade_market_settlements_buyer_state_id_fkey
  foreign key (buyer_state_id) references fauxlore.state_profiles(state_id) on delete cascade;
alter table fauxlore.trade_market_settlements drop constraint trade_market_settlements_seller_state_id_fkey;
alter table fauxlore.trade_market_settlements add constraint trade_market_settlements_seller_state_id_fkey
  foreign key (seller_state_id) references fauxlore.state_profiles(state_id) on delete cascade;
alter table fauxlore.trade_interzone_settlements drop constraint trade_interzone_settlements_buyer_state_id_fkey;
alter table fauxlore.trade_interzone_settlements add constraint trade_interzone_settlements_buyer_state_id_fkey
  foreign key (buyer_state_id) references fauxlore.state_profiles(state_id) on delete cascade;
alter table fauxlore.trade_interzone_settlements drop constraint trade_interzone_settlements_seller_state_id_fkey;
alter table fauxlore.trade_interzone_settlements add constraint trade_interzone_settlements_seller_state_id_fkey
  foreign key (seller_state_id) references fauxlore.state_profiles(state_id) on delete cascade;

-- The feed uses the snapshot when the live state row no longer exists.
do $migration$
declare definition text;
begin
  definition:=pg_get_functiondef('fauxlore.wall_api(text,jsonb)'::regprocedure);
  if position('''state'',s.name' in definition)=0
    or position('''state'',vs.name' in definition)=0
    or position('from fauxlore.wall_verdicts v join fauxlore.map_categories vs' in definition)=0
  then raise exception 'Wall feed attribution hooks missing'; end if;
  definition:=replace(definition,'''state'',s.name','''state'',coalesce(s.name,p.state_name)');
  definition:=replace(definition,'''state'',vs.name','''state'',coalesce(vs.name,v.state_name)');
  definition:=replace(definition,'from fauxlore.wall_verdicts v join fauxlore.map_categories vs',
    'from fauxlore.wall_verdicts v left join fauxlore.map_categories vs');
  execute definition;
end $migration$;
