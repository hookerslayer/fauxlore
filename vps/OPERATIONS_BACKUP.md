# Резервные копии Fauxlore на VPS

## Текущее состояние

- Тестовый стек продолжает использовать `fauxlore_restore_filtered`. Для сайта, переключённого на VPS, используется база `fauxlore_production_candidate`. Это production-база текущего релиза; прежний тестовый стек продолжает использовать `fauxlore_restore_filtered`.
- Созданный 3 ноября 2026 года архив `/root/fauxlore-backups/fauxlore-stage-20261103.dump` содержит права PostgreSQL и проверен восстановлением.
- Проверенная независимая копия находится локально в `.local/vps-backups/fauxlore-stage-20261103.dump`. SHA-256 копии на VPS и компьютере совпал. Каталог `.local` исключён из Git.
- Тест восстановления находится в отдельной базе `fauxlore_recovery_20261103` на том же VPS. Она занимает около 48 МБ, содержит 5 713 провинций и не используется сервисами. Это проверка чтения архива, не независимая резервная копия.
- Candidate-архив также восстановлен в отдельную `fauxlore_recovery_production_20261103`; `pg_restore --single-transaction --exit-on-error` завершился успешно, контрольный запрос показал 5 713 провинций и размер около 48 МБ. Эту базу не используют службы.
- После включения домена и завершения владельцем Google OAuth создан свежий архив `/var/backups/fauxlore/fauxlore_production_candidate-20261102T222720Z.dump`; копия `.local/vps-backups/fauxlore_production_candidate-20261102T222720Z.dump` сверена по SHA-256 (оба значения `69938c30772f7759c61ea3350d625aa4cfe6ea512e6a79bfee0cbfd96063366b`).
- Провайдерскую недельную копию ещё не удалось подтвердить в личном кабинете; платные опции не менялись.
- Для `fauxlore_production_candidate` включён отдельный ежедневный timer и лимит в семь архивов. Копия `/var/backups/fauxlore/fauxlore_production_candidate-20261102T220812Z.dump` прошла полный запуск service и `pg_restore --list`; локальная копия `.local/vps-backups/fauxlore_production_candidate-20261102T220812Z.dump` сохранена, SHA-256 совпал. Это независимая копия от VPS, но она остаётся в компьютере владельца; удалённого внешнего backup-хранилища пока нет.

## Регулярная копия изолированной базы

Файлы `fauxlore-db-backup-preview.sh`, `fauxlore-db-backup-preview.service` и `fauxlore-db-backup-preview.timer` создают еженедельный архив именно базы `fauxlore_restore_filtered`:

- время — каждое воскресенье около 03:00 UTC, с разбросом до 15 минут;
- архив — `/var/backups/fauxlore/`;
- формат — custom PostgreSQL, включая grants и владельцев;
- проверка читаемости выполняется командой `pg_restore --list`;
- сохраняются четыре последних успешно созданных архива в этом отдельном каталоге;
- файлы и каталог доступны только системному пользователю `postgres`.

Эта автоматизация защищает от части ошибок и случайной порчи текущего диска, но сама по себе не защищает от потери VPS. После создания каждой нужной копии перенести её на доверенное независимое хранилище и сравнить SHA-256. Не отправлять дампы в Git, публичные чаты или внешние сервисы без шифрования и явного решения владельца.

Для отдельной candidate-базы настроены `fauxlore-db-backup-production-candidate.service` и `.timer`; после публичного переключения timer переведён на ежедневный запуск около 03:00 UTC с разбросом до 10 минут. Скрипт `/usr/local/sbin/fauxlore-db-backup-production-candidate` сохраняет только архивы с префиксом `fauxlore_production_candidate-` в тот же закрытый каталог и оставляет семь последних. Не менять имя БД в скрипте без обновления соответствующего service и проверки `systemd-analyze verify`.

Команды проверки расписания и последнего запуска (на VPS):

```sh
systemctl list-timers fauxlore-db-backup-preview.timer
systemctl status fauxlore-db-backup-preview.service --no-pager
find /var/backups/fauxlore -maxdepth 1 -type f -name 'fauxlore_restore_filtered-*.dump' -printf '%TY-%Tm-%Td %TH:%TM %s bytes %p\n' | sort
```

## Создать и проверить архив вручную

Выполнять от root на VPS. Имя нового файла должно быть уникальным. Секреты для дампа не нужны.

```sh
set -eu
backup=/root/fauxlore-backups/fauxlore-restore-filtered-YYYYMMDDTHHMMSSZ.dump
temporary=/tmp/fauxlore-restore-filtered-manual.dump
test ! -e "$backup"
test ! -e "$temporary"
sudo -u postgres sh -c "umask 077; /usr/lib/postgresql/17/bin/pg_dump -p 5433 -Fc -d fauxlore_restore_filtered -f $temporary"
/usr/lib/postgresql/17/bin/pg_restore --list "$temporary" >/dev/null
install -o root -g root -m 0600 "$temporary" "$backup"
rm -f "$temporary"
```

`pg_restore --list` проверяет структуру архива, но не заменяет тест полного восстановления. Перед любым изменением БД сначала сделать архив и убедиться, что проверка завершилась с кодом 0.

## Скопировать архив на компьютер владельца

Из PowerShell, находясь в каталоге проекта:

```powershell
New-Item -ItemType Directory -Force -Path '.local\vps-backups' | Out-Null
scp -i "$env:USERPROFILE\.ssh\fauxlore_vps_ed25519" root@89.125.38.213:/root/fauxlore-backups/ИМЯ_АРХИВА.dump '.local\vps-backups\'
Get-FileHash -Algorithm SHA256 '.local\vps-backups\ИМЯ_АРХИВА.dump'
```

Сравнить полученную контрольную сумму с `sha256sum` того же файла на VPS. Успешный `scp` без совпадения контрольных сумм не считать проверенной копией.

## Проверенное восстановление в новую БД

Никогда не восстанавливать архив с `--clean` поверх используемой базы. Выбрать свободное новое имя, например `fauxlore_recovery_YYYYMMDD`, и убедиться, что его ещё нет. Следующие команды рассчитаны на восстановление в том же кластере PostgreSQL 17, где уже существуют используемые DB-роли:

```sh
set -eu
database=fauxlore_recovery_YYYYMMDD
archive=/root/fauxlore-backups/ИМЯ_АРХИВА.dump
temporary=/tmp/fauxlore-recovery.dump
test ! -e "$temporary"
sudo -u postgres /usr/lib/postgresql/17/bin/createdb -p 5433 -T template0 "$database"
install -o postgres -g postgres -m 0600 "$archive" "$temporary"
sudo -u postgres /usr/lib/postgresql/17/bin/pg_restore --single-transaction --exit-on-error -p 5433 -d "$database" "$temporary"
rm -f "$temporary"
sudo -u postgres /usr/lib/postgresql/17/bin/psql -X -p 5433 -d "$database" -Atqc "SELECT current_database(), (SELECT count(*) FROM fauxlore.provinces), pg_size_pretty(pg_database_size(current_database()))"
```

Если архив получен из старого снимка с `--no-acl`, права не восстановлены. Если восстанавливать на другом PostgreSQL-кластере, сначала отдельно подготовить и проверить роли/права; не подключать тестовые роли к публичным сервисам вслепую. Не удалять архив, исходную базу или тестовую БД восстановления автоматически.
