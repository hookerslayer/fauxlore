create or replace function fauxlore.allocate_trade_market_demand(zone_value integer,resource_value text,supply_value numeric)
returns table(state_id integer,allocation numeric,influence numeric)
language plpgsql security definer set search_path='' as $$
declare total_demand numeric(14,2); remaining_value numeric(14,2); total_weight numeric(20,4); average_influence numeric(20,4); buyer record; share_value numeric(14,2); given_value numeric(14,2); seq_value integer; active_count integer;
begin
 create temporary table if not exists pg_temp.trade_buyer_allocations(state_id integer primary key,requested numeric(14,2) not null,influence numeric(14,2) not null,weight numeric(20,4) not null,allocated numeric(14,2) not null default 0) on commit drop;
 truncate pg_temp.trade_buyer_allocations;
 with buyers as (select pos.state_id,(-pos.balance)::numeric(14,2) requested,fauxlore.trade_zone_influence(pos.state_id,zone_value)::numeric(14,2) raw_influence from pg_temp.trade_zone_position pos where pos.zone_id=zone_value and pos.resource_name=resource_value and pos.balance<0),
 avg_value as (select coalesce(avg(buyers.raw_influence),0)::numeric(20,4) amount from buyers)
 insert into pg_temp.trade_buyer_allocations(state_id,requested,influence,weight)
 select b.state_id,b.requested,b.raw_influence,round(b.requested*(1+case when a.amount<=0 then 0 else b.raw_influence/(b.raw_influence+a.amount) end),4) from buyers b cross join avg_value a;
 select coalesce(sum(requested),0)::numeric(14,2) into total_demand from pg_temp.trade_buyer_allocations;
 remaining_value:=least(greatest(supply_value,0),total_demand)::numeric(14,2);
 if remaining_value>=total_demand then update pg_temp.trade_buyer_allocations set allocated=requested;
 else while remaining_value>.004 loop
   select coalesce(sum(weight),0) into total_weight from pg_temp.trade_buyer_allocations where allocated<requested;
   select count(*) into active_count from pg_temp.trade_buyer_allocations where allocated<requested;
   if total_weight<=0 or active_count=0 then exit; end if; given_value:=0;seq_value:=0;
   for buyer in select * from pg_temp.trade_buyer_allocations where allocated<requested order by state_id loop
    seq_value:=seq_value+1; if seq_value=active_count then share_value:=remaining_value-given_value; else share_value:=round(remaining_value*buyer.weight/total_weight,2); end if;
    share_value:=least(share_value,buyer.requested-buyer.allocated);
    if share_value>0 then update pg_temp.trade_buyer_allocations as target set allocated=target.allocated+share_value where target.state_id=buyer.state_id; given_value:=given_value+share_value; end if;
   end loop;
   if given_value<=0 then exit; end if; remaining_value:=remaining_value-given_value;
  end loop;
 end if;
 return query select b.state_id,b.allocated,b.influence from pg_temp.trade_buyer_allocations b where b.allocated>0 order by b.state_id;
end $$;
