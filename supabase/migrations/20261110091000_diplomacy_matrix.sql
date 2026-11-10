-- Матрица дипломатических отношений между государствами.
do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to create diplomacy matrix outside production candidate';
  end if;
end
$guard$;

create or replace function fauxlore.diplomacy_matrix_api()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  account_row fauxlore.accounts;
begin
  account_row := fauxlore.current_account();
  if account_row.id is null then raise sqlstate '28000' using message = 'Войдите через Google'; end if;
  return (
    with states as (
      select c.id, c.name
      from fauxlore.map_categories c
      join fauxlore.state_profiles sp on sp.state_id = c.id
      where c.layer = 'states'
    ),
    pairs as (
      select least(a.id, b.id) a, greatest(a.id, b.id) b
      from states a join states b on a.id < b.id
    ),
    flags as (
      select p.a, p.b,
        exists(select 1 from fauxlore.military_wars w
               where w.active and least(w.attacker_id, w.defender_id) = p.a
                 and greatest(w.attacker_id, w.defender_id) = p.b) as war,
        exists(select 1 from fauxlore.state_marriages m
               join fauxlore.state_characters ca on ca.id = m.character_a_id
               join fauxlore.state_characters cb on cb.id = m.character_b_id
               where m.ended_at_turn is null and ca.state_id <> cb.state_id
                 and least(ca.state_id, cb.state_id) = p.a
                 and greatest(ca.state_id, cb.state_id) = p.b) as marriage,
        exists(select 1 from fauxlore.trade_agreements t
               where t.status = 'accepted'
                 and least(t.from_state_id, t.to_state_id) = p.a
                 and greatest(t.from_state_id, t.to_state_id) = p.b) as trade,
        exists(select 1 from fauxlore.military_wars w
               where not w.active and w.peace_terms is not null
                 and least(w.attacker_id, w.defender_id) = p.a
                 and greatest(w.attacker_id, w.defender_id) = p.b) as peace
      from pairs p
    )
    select jsonb_build_object(
      'states', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name) from states s), '[]'::jsonb),
      'relations', coalesce((select jsonb_agg(jsonb_build_object(
        'a', f.a, 'b', f.b, 'war', f.war, 'marriage', f.marriage,
        'trade', f.trade, 'peace', f.peace) order by f.a, f.b) from flags f), '[]'::jsonb)));
end
$fn$;

create or replace function public.diplomacy_matrix_api()
returns jsonb
language sql
set search_path to 'pg_catalog', 'fauxlore'
as $fn$
  select fauxlore.diplomacy_matrix_api();
$fn$;

grant execute on function public.diplomacy_matrix_api() to authenticated;
grant execute on function fauxlore.diplomacy_matrix_api() to authenticated;
