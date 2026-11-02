create function public.judge_state_statistics_api()
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor fauxlore.accounts;
begin
 actor:=fauxlore.current_account();
 if actor.id is null then raise sqlstate '42501' using message='Войдите в аккаунт'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',sp.state_id,'name',c.name,'treasury',sp.treasury,'prestige',sp.prestige,'recruits',sp.recruits,'crime',sp.crime,'corruption',sp.corruption,'provinces',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'type',p.province_type,'population',p.population,'development',p.development) order by p.name,p.id) from fauxlore.province_values v join fauxlore.provinces p on p.id=v.province_id where v.layer='states' and v.category_id=sp.state_id and p.kind='land'),'[]'::jsonb)) order by c.name) from fauxlore.state_profiles sp join fauxlore.map_categories c on c.layer='states' and c.id=sp.state_id where fauxlore.judge_can_review(actor.id,sp.state_id)),'[]'::jsonb);
end $$;
revoke all on function public.judge_state_statistics_api() from public,anon;
grant execute on function public.judge_state_statistics_api() to authenticated;
notify pgrst,'reload schema';
