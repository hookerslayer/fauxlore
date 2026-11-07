-- Удаление маркера не должно упираться в FK постройки порта.
--
-- Администратор обязан уметь снести порт игрока, в том числе ошибочно
-- поставленный. Раньше `military_port_builds.marker_id` ссылался на
-- `map_markers` без `on delete`, поэтому удаление порта падало с ошибкой
-- «violates foreign key constraint military_port_builds_marker_id_fkey».
-- Теперь запись о постройке уходит вместе с маркером, а содержание порта
-- (`fauxlore.port_upkeep`) перестаёт начисляться автоматически.
--
-- Откат: пересоздать ограничение без `on delete cascade` (потребует
-- предварительно почистить висячие строки `military_port_builds`).

alter table fauxlore.military_port_builds
  drop constraint if exists military_port_builds_marker_id_fkey;
alter table fauxlore.military_port_builds
  add constraint military_port_builds_marker_id_fkey
  foreign key(marker_id) references fauxlore.map_markers(id) on delete cascade;
