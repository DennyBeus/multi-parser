# Multi-Parser

<p align="center">
  <strong>Детерминированный агрегатор техновостей — дёшево, точно, ноль токенов LLM в пайплайне.</strong>
</p>

<p align="center">
  <a href="https://github.com/DennyBeus/multi-parser/actions/workflows/test.yml?branch=main"><img src="https://img.shields.io/github/actions/workflow/status/DennyBeus/multi-parser/test.yml?branch=main&style=for-the-badge" alt="CI status"></a>
  <a href="https://github.com/DennyBeus/multi-parser/releases"><img src="https://img.shields.io/github/v/release/DennyBeus/multi-parser?include_prereleases&style=for-the-badge" alt="GitHub release"></a>
  <a href="https://img.shields.io/badge/python-3.8+-blue"><img src="https://img.shields.io/badge/python-3.8+-blue.svg?style=for-the-badge" alt="Python 3.8+"></a>
</p>

[English](README.md) | **Русский**

## Зачем Multi-Parser?

Multi-Parser создан как **дешёвая и детерминированная замена** скиллу AI-агента для ежедневного дайджеста. Вместо того чтобы тратить токены LLM на сбор, фильтрацию и дедупликацию новостей, этот пайплайн делает всё на чистом Python — без вызовов LLM, без галлюцинаций, без лишних расходов.

**Парсер и агент работают отдельно.** Пайплайн записывает структурированные данные в PostgreSQL; агент обращается к базе только когда нужно составить дайджест. Это означает ноль дополнительных токенов на сбор данных — агент тратит токены только на финальное резюме и доставку.

> Конфигурация агента для работы с этим пайплайном будет опубликована в отдельном репозитории.

## Что он делает

Собирает техновости из **93 источников** 5 типов, оценивает качество, дедуплицирует и сохраняет в PostgreSQL — готово для любого потребителя данных.

| Тип источника | Количество | Примеры |
|---|---|---|
| RSS | 21 лента | Simon Willison, Hugging Face, OpenAI, The Verge AI, Ars Technica... |
| Twitter/X | 45 KOL | @karpathy, @sama, @elonmusk, @VitalikButerin, @AndrewYNg... |
| GitHub | 19 репозиториев | LangChain, vLLM, DeepSeek, Llama, Ollama, Open WebUI... |
| Reddit | 8 сабреддитов | r/MachineLearning, r/LocalLLaMA, r/artificial... |
| Веб-поиск | по топикам | Brave Search или Tavily API с фильтрами свежести |

## Пайплайн

```
cron/run-digest.sh (каждые 12ч)
       │
       ▼
 run-pipeline-db.py
   ├── pipeline_runs → INSERT (status='running')
   ├── run-pipeline.py
   │     ├── fetch-rss.py ──────┐
   │     ├── fetch-twitter.py ──┤
   │     ├── fetch-github.py ───┤  параллельный сбор (~30с)
   │     ├── fetch-github.py ───┤  (--trending)
   │     ├── fetch-reddit.py ──┤
   │     └── fetch-web.py ──────┘
   │              │
   │              ▼
   │     merge-sources.py
   │     (деdup URL → схожесть заголовков → кросс-топик деdup → скоринг)
   │              │
   │              ▼
   │     enrich-articles.py (опционально, полный текст для топ-статей)
   │              │
   │              ▼
   │     итоговый JSON
   ├── store-merged.py → PostgreSQL (articles + seen_urls)
   └── pipeline_runs → UPDATE (status='ok')
```

### Скоринг качества

| Сигнал | Баллы | Условие |
|---|---|---|
| Кросс-источник | +5 | Одна новость из 2+ типов источников |
| Приоритетный источник | +3 | Ключевые блоги/аккаунты |
| Свежесть | +2 | Опубликовано < 24ч назад |
| Twitter engagement | +1 до +5 | По уровню лайков/ретвитов |
| Reddit score | +1 до +5 | По уровню апвотов |
| Дубликат | -10 | Тот же URL уже есть |
| Уже публиковалось | -5 | URL в seen_urls (последние 14 дней) |

### Дедупликация

Три фазы: **нормализация URL** → **схожесть заголовков** (порог 0.75 через SequenceMatcher с токен-бакетами) → **кросс-топик дедупликация** (каждая статья только в одном топике). Лимит домена: максимум 3 статьи с одного домена на топик (исключения: x.com, github.com, reddit.com).

## Быстрый старт

### Требования

- Python 3.8+
- Docker и Docker Compose (для PostgreSQL)
- Хотя бы один API-ключ для Twitter или веб-поиска (опционально, но рекомендуется)

### Автоматическая установка (VPS / Linux)

Скрипт `run-setup.sh` делает всё за один запуск — идеально для чистого VPS:

```bash
git clone https://github.com/DennyBeus/multi-parser.git
cd multi-parser

# 1. Настроить переменные окружения
cp .env.example .env
nano .env    # как минимум задать POSTGRES_PASSWORD и DATABASE_URL

# 2. Запустить установку (ставит зависимости, поднимает Postgres, накатывает миграции, настраивает cron)
chmod +x run-setup.sh
./run-setup.sh
```

Скрипт идемпотентен — безопасно запускать повторно. Он:
1. Установит `python3-pip`, `docker.io`, `docker-compose`, `apparmor`
2. Добавит текущего пользователя в группу `docker`
3. Установит Python-зависимости из `requirements.txt`
4. Поднимет PostgreSQL 16 через Docker Compose
5. Применит миграции базы данных
6. Провалидирует конфиг
7. Настроит cron (05:00 и 17:00 UTC ежедневно)

### Ручная установка

```bash
# Установить зависимости
pip install -r requirements.txt

# Запустить PostgreSQL
docker-compose up -d

# Применить миграции
python db/migrate.py

# Проверить конфиг
python scripts/validate-config.py config/defaults

# Тестовый запуск (только JSON, без БД)
python scripts/run-pipeline.py --only rss,github --output /tmp/test-digest.json

# Полный запуск с записью в БД
python scripts/run-pipeline-db.py --hours 48 --output /tmp/digest.json --verbose
```

## Переменные окружения

Все API-ключи опциональны. Пайплайн работает с тем что есть.

```bash
# PostgreSQL (обязательно для режима с БД)
POSTGRES_PASSWORD=your_password
DATABASE_URL=postgresql://multi_parser_user:your_password@127.0.0.1:5432/multi_parser

# Twitter/X — хотя бы один рекомендуется (приоритет: getxapi > twitterapiio > official)
GETX_API_KEY=
TWITTERAPI_IO_KEY=
X_BEARER_TOKEN=

# Веб-поиск — хотя бы один рекомендуется (приоритет: brave > tavily)
BRAVE_API_KEYS=k1,k2,k3    # через запятую для ротации
TAVILY_API_KEY=

# GitHub — опционально, улучшает rate limits
GITHUB_TOKEN=
```

## Конфигурация

### Источники и топики

- `config/defaults/sources.json` — 93 встроенных источника (21 RSS, 45 Twitter, 19 GitHub, 8 Reddit)
- `config/defaults/topics.json` — определения топиков с поисковыми запросами и фильтрами

Пользовательские оверрайды в `workspace/config/` имеют приоритет. Оверлей **мержится** с дефолтами:

```json
{
  "sources": [
    {"id": "my-blog", "type": "rss", "enabled": true, "url": "https://myblog.com/feed"},
    {"id": "openai-blog", "enabled": false}
  ]
}
```

- **Переопределить** источник — совпадение по `id`
- **Добавить** новый — уникальный `id`
- **Отключить** встроенный — `"enabled": false`

### Расписание cron

По умолчанию: каждые 12 часов (05:00 и 17:00 UTC). Изменить в `run-setup.sh` перед запуском:

```bash
CRON_SCHEDULE="0 5,17 * * *"
```

## База данных

PostgreSQL 16 (Docker), 3 таблицы:

| Таблица | Назначение |
|---|---|
| `pipeline_runs` | Трекинг каждого запуска cron (время, статус, ошибка) |
| `articles` | Статьи после мержа/скоринга (UNIQUE по run_id + normalized_url) |
| `seen_urls` | Кросс-запусковая дедупликация — заменяет сканирование архивов |

Автоочистка: статьи старше 90 дней и seen_urls старше 180 дней удаляются после каждого запуска пайплайна.

Настройки памяти для VPS с 4GB RAM предконфигурированы в `docker-compose.yml` (256MB shared_buffers, 20 max connections).

## Структура проекта

```
multi-parser/
├── config/
│   ├── defaults/
│   │   ├── sources.json          # 93 встроенных источника
│   │   └── topics.json           # определения топиков и поисковые запросы
│   └── schema.json               # JSON Schema для валидации
├── cron/
│   └── run-digest.sh             # обёртка для cron (каждые 12ч)
├── db/
│   ├── migrate.py                # раннер миграций
│   └── migrations/
│       ├── 001_initial.sql       # основная схема (3 таблицы + индексы)
│       └── 002_cleanup_retention.sql  # функция автоочистки
├── scripts/
│   ├── run-pipeline.py           # главный оркестратор (параллельный сбор)
│   ├── run-pipeline-db.py        # обёртка с БД (пайплайн + хранение)
│   ├── fetch-rss.py              # сборщик RSS/Atom лент
│   ├── fetch-twitter.py          # сборщик Twitter/X (3 бэкенда)
│   ├── fetch-github.py           # GitHub releases + trending
│   ├── fetch-reddit.py           # Reddit через публичный API
│   ├── fetch-web.py              # веб-поиск Brave/Tavily
│   ├── merge-sources.py          # движок дедупликации и скоринга
│   ├── enrich-articles.py        # опциональное обогащение полным текстом
│   ├── store-merged.py           # JSON → PostgreSQL
│   ├── config_loader.py          # двухслойный оверлей конфига
│   ├── db_conn.py                # хелпер подключения к БД
│   ├── cleanup-db.py             # ручная очистка БД
│   ├── source-health.py          # проверка доступности источников
│   ├── validate-config.py        # валидация конфига
│   └── delivery/                 # Фаза 2: форматирование вывода
│       ├── generate-pdf.py
│       ├── sanitize-html.py
│       └── send-email.py
├── tests/
│   ├── test_config.py
│   ├── test_db.py
│   ├── test_merge.py
│   └── fixtures/                 # тестовые данные для каждого типа источника
├── docker-compose.yml            # PostgreSQL 16 + тюнинг
├── requirements.txt              # 4 зависимости
├── run-setup.sh                  # установка на VPS за один запуск
├── .env.example                  # шаблон переменных окружения
└── .github/workflows/test.yml    # CI: Python 3.9 + 3.12
```

## Зависимости

Минимум by design — 4 пакета:

```
feedparser>=6.0.0        # парсинг RSS/Atom (фоллбэк на regex без него)
jsonschema>=4.0.0        # валидация конфига
psycopg2-binary>=2.9.0   # драйвер PostgreSQL
python-dotenv>=1.0.0     # загрузка .env файлов
```

## Запуск отдельных сборщиков

Каждый скрипт сбора работает автономно:

```bash
python scripts/fetch-rss.py --defaults config/defaults --output rss.json
python scripts/fetch-twitter.py --defaults config/defaults --output twitter.json --hours 48
python scripts/fetch-github.py --defaults config/defaults --output github.json
python scripts/fetch-reddit.py --defaults config/defaults --output reddit.json
python scripts/fetch-web.py --defaults config/defaults --output web.json
```

## Тесты

```bash
# Все тесты
python -m unittest discover -s tests -v

# Один файл
python -m unittest tests/test_merge.py -v
python -m unittest tests/test_db.py -v
```

CI запускается на Python 3.9 и 3.12 через GitHub Actions.

## Происхождение

Форк [draco-agent/tech-news-digest](https://github.com/draco-agent/tech-news-digest), переработанный: консолидация в один AI-топик, обновлённые источники, автоматическая установка на VPS и адаптация как standalone бэкенд данных для workflow ежедневного дайджеста AI-агента.
