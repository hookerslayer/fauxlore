create or replace function public.government_form_preview_api(chosen jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  account_value fauxlore.accounts;
  form_value text;
begin
  account_value:=fauxlore.current_account();
  if account_value.id is null then
    raise sqlstate '42501' using message='Требуется войти в аккаунт';
  end if;
  if jsonb_typeof(chosen) is distinct from 'object' then
    return jsonb_build_object('valid',false,'error','Выберите все принципы государства.');
  end if;
  begin
    form_value:=fauxlore.government_form(chosen);
    return jsonb_build_object('valid',true,'government_name',form_value);
  exception when sqlstate '22023' then
    return jsonb_build_object('valid',false,'error',sqlerrm);
  end;
end;
$$;
revoke all on function public.government_form_preview_api(jsonb) from public,anon;
grant execute on function public.government_form_preview_api(jsonb) to authenticated;
notify pgrst,'reload schema';
