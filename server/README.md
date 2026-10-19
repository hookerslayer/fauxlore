# PostgreSQL и API

Приложение теперь требует API. `python -m http.server` не обслуживает базу и
авторизацию. Для локального запуска Windows:

```powershell
powershell -ExecutionPolicy Bypass -File tools/start-local.ps1
```

Открыть http://127.0.0.1:8002 . Скрипт создаёт `.venv`, скачивает переносимые
официальные бинарные файлы PostgreSQL 17 от EDB, запускает их ТОЛЬКО на
127.0.0.1:55432 (не системная служба) и запускает FastAPI. Первый запуск
долгий из-за размера архива. Уже установленный PostgreSQL тоже подходит:
задайте `DATABASE_URL`, тогда загрузка/запуск переносимого PostgreSQL пропускаются.

Если Python не в PATH, создайте .venv доступным интерпретатором вручную.
Существующий сервер на 8001 можно оставить: новый интерфейс открывать на 8002.

Linux / готовый PostgreSQL:

```sh
python -m venv .venv
. .venv/bin/activate
pip install -r requirements.lock.txt
export DATABASE_URL='postgresql://fauxlore:PASSWORD@127.0.0.1:5432/fauxlore'
export APP_ORIGIN='http://127.0.0.1:8002'
python -m uvicorn server.app:app --host 127.0.0.1 --port 8002
```

Секреты и кластер в `.local/`, они не попадают в Git и НЕ раздаются приложением.
Не копировать работающий каталог pgdata для миграции — использовать pg_dump.
API использует отдельного владельца БД без SUPERUSER, не аккаунт postgres.

## Схема и исходные данные

`schema.sql` — начальная версия схемы. На первом запуске импортируются 5724
провинции. Имена по умолчанию «Провинция ID», категорий, населения и развития
пока нет: они NULL. JSON остаётся источником геометрии для осознанного импорта.
Перезапуск не импортирует всё заново и не стирает пользовательские изменения.

```sh
python -m server.manage init
python -m server.manage import-map
```

Повторный import-map обновляет геометрию существующих ID, сохраняет имена,
не удаляет автоматически исчезнувшие ID с возможными игровыми связями.
Бинарная геометрия и тайлы остаются статическими файлами, не строками пикселей.

`map_categories(layer,id,name,color)` и `province_values(province_id,layer,category_id)`
хранят категории слоёв states/races/religions/resources/trade/climate. Назначения
отражаются в заливке, легенде, подписях и карточке. Population/development в
provinces, плотность = population/area. Нет данных — базовая заливка и явная
подпись в легенде. Интерфейс наполнения этих справочников требует отдельных
игровых правил и пока не сделан.

## Аккаунты

Регистрация всегда создаёт player. Admin назначается только оператором:

```sh
python -m server.manage create-admin --email you@example.com
# Или повысить уже зарегистрированного пользователя:
python -m server.manage promote-admin --email you@example.com
```

Пароль вводится через getpass, не аргумент командной строки. Общих паролей и
автоматического администратора нет. Пароли хешируются Argon2; сессии — случайные
токены в HttpOnly/SameSite cookie, в БД только SHA-256 токена. Права проверяются
сервером. Изменения настроек карты сохраняются в аккаунт, гостевые — localStorage.

Локальный сброс пароля: письмо `.eml` сохраняется в `.local/mail/`, открыть его
на сервере и перейти по ссылке. SMTP не имитируется сообщением «доставлено».
Ссылка действует 30 минут, одноразовая; сброс отзывает все сессии.
Для реальной почты настроить SMTP_HOST/PORT/FROM/USER/PASSWORD и APP_ORIGIN.

## Развёртывание

Перед публичным размещением: HTTPS reverse proxy, COOKIE_SECURE=1,
APP_ENV=production, явный APP_ORIGIN, SMTP, отдельный DB-пользователь, закрытый
порт PostgreSQL и внешние резервные копии. Не публиковать dev http.server из
корня проекта: он не использует whitelist и способен раздать локальные файлы.
Приложение разрешает только перечисленные публичные файлы/иконки/тайлы.
Для нескольких worker'ов заменить локальный limiter общим хранилищем;
здесь один процесс Uvicorn. Подтверждение email пока не реализовано.

Локально Ctrl+C останавливает API. PostgreSQL остаётся доступен для последующей
работы; его можно корректно остановить отдельно:

```powershell
& ./.local/pgsql/bin/pg_ctl.exe -D .local/pgdata -m fast stop
```

`requirements.txt` — прямые зависимости, `requirements.lock.txt` — проверенные
версии вместе с транзитивными зависимостями для воспроизводимого запуска.

Пример переноса: pg_dump --format=custom, затем pg_restore в подготовленную БД.
Версию PostgreSQL на сервере выбирать совместимую, а не копировать Windows-бинарники.

Тесты (на отдельной временной схеме той же БД, данные игры не изменяют):

```sh
python -m unittest server.test_api -v
node tools/test_map_tools.mjs
node tools/test_view_region.cjs
```
