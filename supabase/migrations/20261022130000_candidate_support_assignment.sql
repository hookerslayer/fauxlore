create or replace function fauxlore.prepare_succession_support()
returns trigger language plpgsql security definer set search_path='' as $$
declare candidate jsonb; prepared jsonb:='[]'::jsonb; support_map jsonb:='{}'::jsonb; assignments jsonb:='{}'::jsonb;
  estate_name text; i integer; chosen_slot integer; estate_weight numeric; support_weight numeric;
  province_votes integer[]:=array[0,0,0]; authority_value text; is_key boolean;
begin
  perform fauxlore.ensure_state_group_politics(new.state_id);
  authority_value:=new.authority;
  if authority_value='Вече' then
    for i in select 1+floor(random()*3)::int from fauxlore.province_values where layer='states' and category_id=new.state_id loop
      province_votes[i]:=province_votes[i]+1;
    end loop;
  else
    for estate_name in select unnest(array['Корона','Знать','Духовенство','Горожане','Крестьяне']) loop
      is_key:=fauxlore.estate_status_for(new.state_id,estate_name)='Ключевое';
      if authority_value='Клир' and estate_name<>'Духовенство' then continue; end if;
      if authority_value in ('Династия','Диктат') and not is_key then continue; end if;
      select coalesce(sum(fauxlore.province_value_for_state(p.id,new.state_id)),0) into estate_weight
        from fauxlore.province_values s join fauxlore.provinces p on p.id=s.province_id and p.kind='land'
        where s.layer='states' and s.category_id=new.state_id and p.belonging=estate_name;
      if estate_weight<=0 then estate_weight:=1; end if;
      assignments:=jsonb_set(assignments,array[estate_name],to_jsonb(1+floor(random()*3)::int),true);
    end loop;
  end if;
  for i in 0..jsonb_array_length(new.candidates)-1 loop
    candidate:=new.candidates->i;
    if authority_value='Вече' then
      candidate:=jsonb_set(candidate,'{support_votes}',to_jsonb(province_votes[i+1]),true);
    else
      support_map:='{}'::jsonb; support_weight:=0;
      for estate_name in select key from jsonb_each(assignments) loop
        chosen_slot:=(assignments->>estate_name)::integer;
        support_map:=support_map||jsonb_build_object(estate_name,chosen_slot=i+1);
        if chosen_slot=i+1 then
          select coalesce(sum(fauxlore.province_value_for_state(p.id,new.state_id)),0) into estate_weight
            from fauxlore.province_values s join fauxlore.provinces p on p.id=s.province_id and p.kind='land'
            where s.layer='states' and s.category_id=new.state_id and p.belonging=estate_name;
          support_weight:=support_weight+greatest(estate_weight,1);
        end if;
      end loop;
      candidate:=jsonb_set(candidate,'{support}',support_map,true);
      candidate:=jsonb_set(candidate,'{support_weight}',to_jsonb(support_weight),true);
    end if;
    prepared:=prepared||jsonb_build_array(candidate);
  end loop;
  new.candidates:=prepared;
  return new;
end $$;
revoke all on function fauxlore.prepare_succession_support() from public,anon,authenticated;
notify pgrst,'reload schema';
