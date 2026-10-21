create or replace function fauxlore.state_characters_payload(target_state_id integer)
returns jsonb language sql security definer set search_path='' as $$
  with ruler as (
    select ch.* from fauxlore.state_characters ch
    where ch.state_id=target_state_id and (ch.is_current_ruler or not exists(
      select 1 from fauxlore.state_characters active where active.state_id=target_state_id and active.is_current_ruler))
    order by ch.is_current_ruler desc,ch.id desc limit 1
  ), relevant as (
    select distinct ch.*,
      case
        when ch.id=(select id from ruler) then case when ch.is_current_ruler then 'Правитель' else 'Бывший правитель' end
        when exists(select 1 from fauxlore.state_marriages m where
          ((m.character_a_id=ch.id and m.character_b_id=(select id from ruler)) or (m.character_b_id=ch.id and m.character_a_id=(select id from ruler))))
          then case when exists(select 1 from fauxlore.state_marriages m where m.ended_at_turn is null and
            ((m.character_a_id=ch.id and m.character_b_id=(select id from ruler)) or (m.character_b_id=ch.id and m.character_a_id=(select id from ruler))))
            then case when ch.gender='Женский' then 'Супруга' else 'Супруг' end else 'Бывший супруг' end
        when ch.id in ((select father_id from ruler),(select mother_id from ruler)) then 'Родитель'
        when (select id from ruler) in (ch.father_id,ch.mother_id) then 'Ребёнок'
        when exists(select 1 from fauxlore.state_characters rr where rr.id=(select id from ruler)
          and ((rr.father_id is not null and rr.father_id in (ch.father_id,ch.mother_id)) or (rr.mother_id is not null and rr.mother_id in (ch.father_id,ch.mother_id)))) then 'Брат/сестра'
        else 'Родственник'
      end as relation
    from fauxlore.state_characters ch
    where ch.state_id=target_state_id and (ch.is_current_ruler or ch.id=(select id from ruler)
      or ch.id in ((select father_id from ruler),(select mother_id from ruler)) or (select id from ruler) in (ch.father_id,ch.mother_id)
      or exists(select 1 from fauxlore.state_marriages m where (m.character_a_id=ch.id and m.character_b_id=(select id from ruler))
        or (m.character_b_id=ch.id and m.character_a_id=(select id from ruler)))
      or exists(select 1 from fauxlore.state_characters rr where rr.id=(select id from ruler)
        and ((rr.father_id is not null and rr.father_id in (ch.father_id,ch.mother_id)) or (rr.mother_id is not null and rr.mother_id in (ch.father_id,ch.mother_id)))))
    union
    select ch.*,case when ch.gender='Женский' then 'Супруга' else 'Супруг' end as relation
    from fauxlore.state_marriages m
    join fauxlore.state_characters ch on ch.id=case when m.character_a_id=(select id from ruler) then m.character_b_id else m.character_a_id end
    where (m.character_a_id=(select id from ruler) or m.character_b_id=(select id from ruler)) and ch.state_id<>target_state_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'name',r.name,'surname',r.surname,'gender',r.gender,'title',r.title,'age',r.age,'race_id',r.race_id,'religion_id',r.religion_id,
    'race',(select c.name from fauxlore.map_categories c where c.layer='races' and c.id=r.race_id),
    'religion',(select c.name from fauxlore.map_categories c where c.layer='religions' and c.id=r.religion_id),
    'alive',r.alive,'legitimacy',r.legitimacy,'is_current_ruler',r.is_current_ruler,'is_regent',r.is_regent,'relationship',r.relation,
    'state_name',(select c.name from fauxlore.map_categories c where c.layer='states' and c.id=r.state_id)
  ) order by r.is_current_ruler desc,r.age desc,r.id),'[]'::jsonb) from relevant r
$$;
notify pgrst,'reload schema';
