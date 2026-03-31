# Настройка tech-news-digest на сервере

> Статус: **в процессе** — не настроено, требует выполнения всех шагов

---

## Что за проект

Автоматический агрегатор техновостей. Собирает статьи из RSS, Twitter/X, GitHub, Reddit, веб-поиска. Хранит в PostgreSQL. Запускается по cron каждые 12 часов. LLM не используется в пайплайне.

---

## Проверка инструментов на сервере (26 марта 2026)

| Инструмент | Нужен | Статус |
|---|---|---|
| Python 3 | да | ✅ 3.11.2 |
| pip | да | ❌ не установлен |
| Docker | да (postgres) | ❌ не установлен |
| psql | опционально | ❌ не установлен |
| feedparser | опционально | ❌ не установлен |
| psycopg2 | да (DB режим) | ❌ не установлен |
| jsonschema | опционально | ✅ уже есть |

---

## Шаг 1 — Установить pip

```bash
sudo apt install python3-pip -y
```

---

## Шаг 2 — Установить зависимости Python

```bash
cd ~/deploy/tech-news-digest
pip3 install -r requirements.txt
```

Устанавливает: `feedparser`, `psycopg2-binary`, `jsonschema`, `python-dotenv`.

> Если Debian ругается на "externally managed":
> ```bash
> pip3 install --break-system-packages -r requirements.txt
> ```

---

## Шаг 3 — Установить Docker

Проект использует Docker для запуска PostgreSQL.

```bash
sudo apt install docker.io docker-compose apparmor -y
sudo usermod -aG docker denis
```

> `apparmor` нужен для запуска контейнеров: Docker использует AppArmor-профиль безопасности, и без утилиты `apparmor_parser` контейнер не стартует с ошибкой `executable file not found in $PATH`.

После `usermod` группа `docker` применится только в новой сессии. Два варианта:

**Вариант А — без выхода (рекомендуется):**
```bash
newgrp docker
```
Активирует группу в текущем терминале без выхода. Работает только в этом окне/сессии tmux.

**Вариант Б — полный перелогин:**
Выйди из SSH и зайди снова под тем же пользователем `denis`:
```bash
exit   # закрываешь SSH-сессию
# затем подключаешься заново: ssh denis@твой_сервер
```
Выходить под другого пользователя не нужно — ты добавил `denis` в группу `docker`, и возвращаешься тоже под `denis`.

**Проверка что группа применилась:**
```bash
groups   # должна появиться строка с "docker"
docker ps   # не должно быть ошибки "permission denied"
```

---

## Шаг 4 — Создать .env файл

```bash
cd ~/deploy/tech-news-digest
nano .env
```

Минимальный `.env` для запуска:
```bash
# Postgres
DATABASE_URL=postgresql://digest:your_pass@127.0.0.1:5432/tech_digest
POSTGRES_PASSWORD=your_pass

# Twitter/X (at least one recommended)
GETX_API_KEY=
TWITTERAPI_IO_KEY=
X_BEARER_TOKEN=

# Web search (at least one recommended)
BRAVE_API_KEYS=
TAVILY_API_KEY=

# GitHub (optional, improves rate limits)
GITHUB_TOKEN=
```

---

## Шаг 5 — Запустить PostgreSQL через Docker

```bash
cd ~/deploy/tech-news-digest
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

---

## Доп. — Подключение DataGrip удалённо (SSH-туннель)

Порт PostgreSQL намеренно привязан только к `127.0.0.1` — в интернет не торчит. Для DataGrip используй SSH-туннель: безопасно, не нужно открывать порт на сервере.

**Настройка в DataGrip:**

1. `New Data Source` → `PostgreSQL`
2. Вкладка **SSH/SSL** → включи `Use SSH tunnel`
3. Заполни SSH:
   - Host: `IP_твоего_VPS`
   - Port: `22`
   - User: `denis`
   - Auth type: `Key pair` (укажи свой приватный ключ) или `Password`
4. Вернись на вкладку **General**, заполни:
   - Host: `localhost`
   - Port: `5432`
   - Database: `tech_digest`
   - User: `digest`
   - Password: тот же что в `POSTGRES_PASSWORD` из `.env`
5. `Test Connection` — должно сработать

> **Предупреждение "remote host identification has changed"** — появляется если сервер пересоздавался или менялась ОС. Нажми **Yes** ("Update key") — DataGrip обновит `known_hosts` и подключится. Это не атака, если ты сам менял сервер.

> DataGrip сам поднимет SSH-туннель при подключении. Ничего на сервере менять не нужно.

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

## Шаг 9 — Настроить cron (каждые 12 часов)

Выполнять из папки проекта — `$(pwd)` автоматически подставит правильный путь:

```bash
cd ~/deploy/tech-news-digest
chmod +x cron/run-digest.sh
mkdir -p logs
(crontab -l 2>/dev/null; echo "0 8,20 * * * $(pwd)/cron/run-digest.sh >> $(pwd)/logs/cron.log 2>&1") | crontab -
```

Проверить что добавилось:
```bash
crontab -l
```

> Очистка БД встроена в `cron/run-digest.sh` — после каждого успешного запуска pipeline автоматически удаляются статьи старше 90 дней и `seen_urls` старше 180 дней. Отдельной cron-задачи не нужно.

---

## Справка: зависимости по источникам

| Источник | Что нужно |
|---|---|
| RSS | feedparser (опц.), без него — regex |
| GitHub releases/trending | `GITHUB_TOKEN` |
| Reddit | ничего (публичный API) |
| Twitter/X | один из 3 ключей |
| Web search | Brave или Tavily API ключ |

---

## TODO

- [ ] Шаг 1: установить pip
- [ ] Шаг 2: установить Python зависимости
- [ ] Шаг 3: установить Docker
- [ ] Шаг 4: создать .env и заполнить ключи
- [ ] Шаг 5: запустить Postgres
- [ ] Шаг 6: применить миграции
- [ ] Шаг 7: проверить конфиг
- [ ] Шаг 8: тестовый запуск
- [ ] Шаг 9: настроить cron
