# Настройка multi-parser на сервере

## Шаг 1 — Установить pip и системные зависимости

```bash
sudo apt update
sudo apt install python3-pip -y

# Системные зависимости для weasyprint и PDF-генерации
sudo apt install fonts-noto-cjk libpango-1.0-0 libpangoft2-1.0-0 libpangocairo-1.0-0 -y
```

> `fonts-noto-cjk` — шрифты для корректной отрисовки русского и восточноазиатских текстов.
> `libpango*` — библиотеки текстовой разметки, необходимы для WeasyPrint при генерации PDF.

---

## Шаг 2 — Установить зависимости Python

```bash
cd ~/deploy/multi-parser
pip3 install -r requirements.txt
```

Устанавливает: `feedparser`, `psycopg2-binary`, `jsonschema`, `python-dotenv`, `weasyprint`.

Если Debian ругается на "externally managed":
```bash
pip3 install --break-system-packages -r requirements.txt
```

> Рекомендуется использовать `--break-system-packages` вместо `sudo pip3` — это безопаснее для вашей системы.

---

## Шаг 3 — Установить Docker

Проект использует Docker для запуска PostgreSQL.

```bash
sudo apt install docker.io docker-compose apparmor -y
sudo usermod -aG docker user # замените user на вашего пользователя
```

> `apparmor` нужен для запуска контейнеров: Docker использует AppArmor-профиль безопасности, и без утилиты `apparmor_parser` контейнер не стартует с ошибкой `executable file not found in $PATH`.

После `usermod` группа `docker` применится только в новой сессии.

```bash
newgrp docker
```
Активирует группу в текущем терминале без выхода. Работает только в этом окне или сессии tmux.

Проверяем что группа применилась:

```bash
groups   # должна появиться строка с "docker"
docker ps   # не должно быть ошибки "permission denied"
```

---

## Шаг 4 — Создать .env файл

```bash
cp .env.example .env
nano .env
```

Отредактируйте следующие поля:
- `POSTGRES_USER` (замените в multi_parser_user в конце `user` на ваше имя)
- `POSTGRES_PASSWORD` (установите свой пароль)
- `DATABASE_URL` (замените multi_parser_user и changeme на ваши `POSTGRES_USER` и `POSTGRES_PASSWORD` соответсвенно)
- `TWITTERAPI_IO_KEY`
- `TAVILY_API_KEY` (1000 бесплатных токенов в месяц)
- `GITHUB_TOKEN` (обходит ограничение по времени)

## Шаг 5 — Запустить PostgreSQL через Docker

```bash
docker-compose up -d
docker-compose ps   # проверить что запустилось
```

---

## Шаг 6 — Применить миграции БД

```bash
python3 db/migrate.py
python3 db/migrate.py --status   # проверить
```

Создаст 3 таблицы: `pipeline_runs`, `articles`, `seen_urls`, и функцию `cleanup_old_articles()` для удаления старых записей.

---

## Шаг 7 — Проверить конфиг

```bash
python3 scripts/validate-config.py --defaults config/defaults
```

---

## Шаг 8 — Тестовый запуск

Сначала без БД (минимальный тест):
```bash
python3 scripts/run-pipeline.py --only rss,github --output /tmp/test-digest.json
```

Если работает — полный запуск с БД:
```bash
python3 scripts/run-pipeline-db.py --hours 48 --output /tmp/td-merged.json --verbose
```

Опционально — тестирование export и PDF-генерации:
```bash
python3 scripts/delivery/export-latest.py --hours 48 --min-score 4 --output /tmp/test-articles.md
python3 scripts/delivery/generate-pdf.py --input /tmp/test-articles.md --output /tmp/test-digest.pdf
```

---

## Шаг 9 — Настроить cron (каждые 24 часа)

Выполнять из папки проекта — `$(pwd)` автоматически подставит правильный путь:

```bash
cd ~/deploy/multi-parser
chmod +x cron/run-parser.sh
mkdir -p logs
(crontab -l 2>/dev/null; echo "0 6 * * * $(pwd)/cron/run-parser.sh >> $(pwd)/logs/cron.log 2>&1") | crontab -
```

Проверить что добавилось:
```bash
crontab -l
```

> Очистка БД встроена в `cron/run-parser.sh` — после каждого успешного запуска pipeline автоматически удаляются статьи старше 90 дней и `seen_urls` старше 180 дней. Отдельной cron-задачи не нужно.

---

## Доп. — Подключение DataGrip удалённо (SSH-туннель)

DataGrip я использую лишь для удобного просмотра таблиц БД. Этот шаг опционален.

Порт PostgreSQL намеренно привязан только к `127.0.0.1` — в интернет не торчит. Для DataGrip используй SSH-туннель: безопасно, не нужно открывать порт на сервере.

**Настройка в DataGrip:**

1. `New Data Source` → `PostgreSQL`
2. Вкладка **SSH/SSL** → включи `Use SSH tunnel`
3. Заполни SSH:
   - Host: `IP_твоего_VPS`
   - Port: `22`
   - User: `user`
   - Auth type: `Key pair` (укажи свой приватный ключ) или `Password`
4. Вернись на вкладку **General**, заполни:
   - Host: `localhost`
   - Port: `5432`
   - Database: `multi-parser`
   - User: `multi-parser-user`
   - Password: тот же что в `POSTGRES_PASSWORD` из `.env`
5. `Test Connection` — должно сработать

---

## Доп. — Память PostgreSQL

Уже настроено в `docker-compose.yml`. При 4GB RAM на VPS выставлены умеренные параметры:

| Параметр | Значение | Что это |
|---|---|---|
| `shared_buffers` | 256MB | Основной кэш БД |
| `work_mem` | 8MB | Память на одну сортировку/запрос |
| `effective_cache_size` | 1GB | Подсказка планировщику |
| `maintenance_work_mem` | 64MB | Для VACUUM и индексов |
| `max_connections` | 20 | Максимум соединений |

Для новостного дайджеста за месяц этого с большим запасом хватит — такие данные занимают обычно 100–500MB даже за год.

> Если меняешь эти параметры после того как контейнер уже запущен — перезапусти: `docker compose down && docker compose up -d`

---