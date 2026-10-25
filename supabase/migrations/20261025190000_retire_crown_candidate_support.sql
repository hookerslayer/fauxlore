-- Existing marriage and succession choices must not retain the retired fifth estate.
update fauxlore.state_marriage_candidates
set supported_by=array_remove(supported_by,'Корона')
where 'Корона'=any(supported_by);

update fauxlore.state_succession_events ev set candidates=(
  select jsonb_agg(
    jsonb_set(
      jsonb_set(c.value,'{support}',coalesce(c.value->'support','{}'::jsonb)-'Корона',true),
      '{support_weight}',
      to_jsonb(coalesce((
        select sum(case when coalesce((c.value->'support'->>e.estate)::boolean,false)
          then greatest(coalesce((
            select sum(fauxlore.province_value_for_state(p.id,ev.state_id)
              * coalesce((select ep.population from fauxlore.estate_population(p.province_type,p.population::bigint) ep where ep.estate=e.estate),0)::numeric
              / greatest(coalesce(p.population,0),1))
            from fauxlore.province_values v join fauxlore.provinces p on p.id=v.province_id and p.kind='land'
            where v.layer='states' and v.category_id=ev.state_id
          ),0),1)
          else 0 end)
        from unnest(array['Знать','Духовенство','Горожане','Крестьяне']) e(estate)
      ),0)),true
    ) order by c.ordinality)
  from jsonb_array_elements(ev.candidates) with ordinality c(value,ordinality)
)
where ev.resolved_at is null and ev.candidates::text like '%Корона%';
