-- Нейтральные формирования и гарнизоны должны быть видны на карте.
--
-- `public.military_map_api()` соединял формирования и гарнизоны с государством
-- через inner join, поэтому строки с `state_id is null` выпадали из ответа и
-- нейтральные чипы не рисовались никому, включая администратора. Заменяем
-- соединения на left join: чип остаётся с пустым государством и цветом по
-- умолчанию, а видимость регулируется прежним условием по провинциям.

do $migration$
declare fn text;
begin
  fn:=pg_get_functiondef('public.military_map_api()'::regprocedure);

  if position('left join fauxlore.map_categories state on state.layer=''states'' and state.id=f.state_id' in fn)=0 then
    if position('join fauxlore.map_categories state on state.layer=''states'' and state.id=f.state_id' in fn)=0 then
      raise exception 'Neutral formation map join not found';
    end if;
    fn:=replace(fn,'join fauxlore.map_categories state on state.layer=''states'' and state.id=f.state_id',
      'left join fauxlore.map_categories state on state.layer=''states'' and state.id=f.state_id');
  end if;

  if position('left join fauxlore.map_categories state on state.layer=''states'' and state.id=g.state_id' in fn)=0 then
    if position('join fauxlore.map_categories state on state.layer=''states'' and state.id=g.state_id' in fn)=0 then
      raise exception 'Neutral garrison map join not found';
    end if;
    fn:=replace(fn,'join fauxlore.map_categories state on state.layer=''states'' and state.id=g.state_id',
      'left join fauxlore.map_categories state on state.layer=''states'' and state.id=g.state_id');
  end if;

  execute fn;
end
$migration$;
