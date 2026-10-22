-- Free automatic resource allocation with influence-weighted demand.
alter table fauxlore.trade_market_settlements add column if not exists buyer_influence numeric(14,2) not null default 0;
alter table fauxlore.trade_interzone_settlements add column if not exists buyer_influence numeric(14,2) not null default 0;
do $$ declare c text; begin
 select conname into c from pg_constraint where conrelid='fauxlore.trade_interzone_settlements'::regclass and contype='c'
 and pg_get_constraintdef(oid) ilike '%buyer_state_id%seller_state_id%' order by conname limit 1;
 if c is not null then execute format('alter table fauxlore.trade_interzone_settlements drop constraint %I',c); end if;
end $$;
create or replace function fauxlore.trade_zone_influence(state_value integer,zone_value integer)
returns numeric language sql stable security definer set search_path='' as $$
 with cfg as (select config from fauxlore.economy_parameters where singleton=true)
 select coalesce(sum((cfg.config#>>array['provinceModifiers',p.province_type,'tradeBase'])::numeric
 *(cfg.config#>>array['provinceModifiers',p.province_type,'trade'])::numeric
 *(cfg.config#>>array['tradeStatusModifiers',coalesce(p.trade_status,'Отсутствует')])::numeric
 *case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then
   case when occupier.id=state_value then coalesce((cfg.config->>'occupationMultiplier')::numeric,.5) else 0 end
  else case when owner.id=state_value then 1 else 0 end end),0)
 from fauxlore.provinces p
 join fauxlore.province_values zone on zone.province_id=p.id and zone.layer='trade' and zone.category_id=zone_value
 left join fauxlore.province_values owner_value on owner_value.province_id=p.id and owner_value.layer='states'
 left join fauxlore.map_categories owner on owner.layer='states' and owner.id=owner_value.category_id
 left join fauxlore.map_categories occupier on occupier.layer='states' and lower(occupier.name)=lower(p.occupation)
 cross join cfg where p.kind='land'
$$;
revoke all on function fauxlore.trade_zone_influence(integer,integer) from public,anon,authenticated;
