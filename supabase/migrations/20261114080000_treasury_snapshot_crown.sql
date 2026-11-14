-- График «Казна» должен показывать казну государства (Корона), а не сумму
-- казн всех сословий. Ранее снимок писал state_profiles.treasury — общий итог.
do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to patch treasury snapshots outside production candidate';
  end if;
end
$guard$;

do $patch$
declare definition text; marker text; replacement text;
begin
  select pg_get_functiondef('fauxlore.capture_state_turn_snapshots()'::regprocedure) into definition;
  marker := $m$coalesce(sp.treasury, 0), coalesce(sp.prestige, 0),$m$;
  if position(marker in definition) = 0 then
    raise exception 'Could not locate treasury expression';
  end if;
  replacement := $m$(select coalesce(sum(t.balance), 0) from fauxlore.state_treasuries t
      where t.state_id = sp.state_id and t.estate = 'Корона'), coalesce(sp.prestige, 0),$m$;
  definition := replace(definition, marker, replacement);
  execute definition;
end
$patch$;

-- Пересоздаём историю: старые точки содержали сумму сословных казн.
delete from fauxlore.state_turn_snapshots;

insert into fauxlore.state_turn_snapshots(state_id, year, turn, treasury, prestige, population, development)
select sp.state_id, cal.year, cal.turn,
  (select coalesce(sum(t.balance), 0) from fauxlore.state_treasuries t
   where t.state_id = sp.state_id and t.estate = 'Корона'),
  coalesce(sp.prestige, 0),
  coalesce(sum(p.population), 0), coalesce(sum(p.development), 0)::integer
from fauxlore.state_profiles sp
cross join fauxlore.game_calendar cal
left join fauxlore.province_values v on v.layer = 'states' and v.category_id = sp.state_id
left join fauxlore.provinces p on p.id = v.province_id and p.kind = 'land'
where cal.singleton
group by sp.state_id, sp.prestige, cal.year, cal.turn
on conflict (state_id, year, turn) do nothing;
