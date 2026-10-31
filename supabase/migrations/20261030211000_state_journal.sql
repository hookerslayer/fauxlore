create table if not exists fauxlore.state_journals (
  state_id integer primary key references fauxlore.state_profiles(state_id) on delete cascade,
  player_note text not null default '',
  admin_note text not null default '',
  player_updated_at timestamptz,
  admin_updated_at timestamptz,
  check (length(player_note) <= 30000),
  check (length(admin_note) <= 30000)
);
alter table fauxlore.state_journals enable row level security;
revoke all on fauxlore.state_journals from public, anon, authenticated;

create or replace function public.state_journal_api(action text, target_state integer, note text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor fauxlore.accounts; journal_row fauxlore.state_journals; owns_state boolean;
begin
  actor := fauxlore.current_account();
  if actor.id is null then raise sqlstate '42501' using message='Требуется войти в аккаунт'; end if;
  if not exists (select 1 from fauxlore.state_profiles where state_id=target_state) then
    raise sqlstate 'P0002' using message='Государство не найдено';
  end if;
  select exists(select 1 from fauxlore.account_states where account_id=actor.id and state_id=target_state) into owns_state;
  if actor.role<>'admin' and not owns_state then
    raise sqlstate '42501' using message='Нет доступа к журналу государства';
  end if;
  if action='save_player' then
    if not owns_state then raise sqlstate '42501' using message='Заметки игрока сохраняет владелец государства'; end if;
    if note is null or length(note)>30000 then raise sqlstate '22023' using message='Длина заметки не должна превышать 30 000 символов'; end if;
    insert into fauxlore.state_journals(state_id,player_note,player_updated_at)
      values(target_state,note,now())
      on conflict(state_id) do update set player_note=excluded.player_note,player_updated_at=excluded.player_updated_at;
  elsif action='save_admin' then
    if actor.role<>'admin' then raise sqlstate '42501' using message='Заметки администратора сохраняет только администратор'; end if;
    if note is null or length(note)>30000 then raise sqlstate '22023' using message='Длина заметки не должна превышать 30 000 символов'; end if;
    insert into fauxlore.state_journals(state_id,admin_note,admin_updated_at)
      values(target_state,note,now())
      on conflict(state_id) do update set admin_note=excluded.admin_note,admin_updated_at=excluded.admin_updated_at;
  elsif action<>'snapshot' then
    raise sqlstate '22023' using message='Неизвестное действие журнала';
  end if;
  select * into journal_row from fauxlore.state_journals where state_id=target_state;
  return jsonb_build_object('state_id',target_state,'player_note',coalesce(journal_row.player_note,''),
    'admin_note',coalesce(journal_row.admin_note,''),'can_edit_player',owns_state,
    'can_edit_admin',actor.role='admin','player_updated_at',journal_row.player_updated_at,
    'admin_updated_at',journal_row.admin_updated_at);
end $$;
revoke all on function public.state_journal_api(text,integer,text) from public, anon;
grant execute on function public.state_journal_api(text,integer,text) to authenticated;
notify pgrst,'reload schema';
