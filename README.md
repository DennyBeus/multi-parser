# Multi-Parser

<a href="https://github.com/DennyBeus/multi-parser">
     <img width="1500" height="801" alt="Multi-Parser" src="https://raw.githubusercontent.com/DennyBeus/multi-parser/main/assets/readme_image.jpg" />
</a>


<br/>
<br/>

<div align="center">
    <strong>Deterministic multi-parser — stop paying for your agent's extra work and mistakes.</strong>
    <br />
    <br />

</div>

<div align="center">

[![Tests](https://github.com/DennyBeus/multi-parser/actions/workflows/test.yml/badge.svg)](https://github.com/DennyBeus/multi-parser/actions/workflows/test.yml) [![Last Update](https://img.shields.io/github/last-commit/DennyBeus/multi-parser?label=Last%20update&style=classic)](https://github.com/DennyBeus/multi-parser) ![GitHub License](https://img.shields.io/github/license/DennyBeus/multi-parser) ![X (formerly Twitter) Follow](https://img.shields.io/twitter/follow/DennyBeus)

</div>

**English | [Русский](README_RU.md)**

Hey there! My name is **Denny**, and I ran into a problem with my agent burning through too many tokens just to put together daily digests. Spending over $50 a month on unnecessary — and sometimes outright wrong — actions from an agent powered by a plain SKILL.md wasn't something I could justify. So I came up with Multi-Parser: let pure code handle the parsing, and let the agent work with ready-made data in a convenient format.
> I wrote more about this in two posts: [Post-1](https://t.me/dennyfun/300) and [Post-2](https://t.me/dennyfun/301).


## Why Multi-Parser?

Multi-Parser was built as a **cheap and deterministic replacement** for an AI agent's daily digest [skill](https://github.com/draco-agent/tech-news-digest). Instead of burning LLM tokens on fetching, filtering, and deduplicating news, this pipeline does everything in pure Python — no LLM calls, no hallucinations, no wasted spend.

**The parser and the agent work separately** — that's the core idea and guiding principle of this project. It was important to draw a clear line of responsibility between pure code and the agent's work. The pipeline writes structured data to PostgreSQL, and the agent only queries the database when it's time to compose a digest. This means zero extra tokens spent on data collection — the agent only uses tokens for the final summary and delivery.

Multi-Parser is a great fit for those running Claude Code or Codex on a server via a subscription. The project’s architecture is built around agent-based calls rather than model API keys, so you won’t have to pay extra, everything is already included in your subscription.

> Agent configuration for working with this pipeline will be published in a separate repository.

## What It Does

Multi-Parser collects AI-related news from **93 sources**, scores quality, deduplicates, and stores everything in PostgreSQL. I hand-picked sources that tend to write in-depth content rather than just two sentences in a tweet. Spammy, low-signal, and reply-only accounts didn't make the cut.

| Source Type | Count | Examples |
|---|---|---|
| RSS | 21 | MIT Technology Review, Hugging Face, OpenAI, Google DeepMind Blog, NVIDIA AI... |
| Twitter/X | 45 | @karpathy, @sama, @demishassabis, @ilyasut, @AndrewYNg... |
| GitHub | 19 | LangChain, vLLM, DeepSeek, Llama, Ollama, Open WebUI... |
| Reddit | 8 | r/MachineLearning, r/LocalLLaMA, r/artificial... |
| Web Search | topic-based | Brave Search or Tavily API with freshness filters |

I especially focused on sources that don't just rehash the news (all of Twitter is guilty of this), but produce original thoughts or ideas, or are the original source.

## Pipeline

The pipeline is straightforward and starts with a regular cron job that runs Python scripts for each source on a schedule. Then other scripts filter, deduplicate, and score the quality of the parsed data, after which a final JSON file is produced and inserted into the database.
```
cron/run-parser.sh (every 24h)
       │
       ▼
 run-pipeline-db.py
   ├── pipeline_runs → INSERT (status='running')
   ├── run-pipeline.py
   │     ├── fetch-rss.py ──────┐
   │     ├── fetch-twitter.py ──┤
   │     ├── fetch-github.py ───┤  parallel fetch (~30s)
   │     ├── fetch-github.py ───┤  (--trending)
   │     ├── fetch-reddit.py  ──┤
   │     └── fetch-web.py ──────┘
   │              │
   │              ▼
   │     merge-sources.py
   │     (URL dedup → title similarity → cross-topic dedup → quality scoring)
   │              │
   │              ▼
   │     enrich-articles.py (optional, full-text for top articles)
   │              │
   │              ▼
   │     merged JSON output
   ├── store-merged.py → PostgreSQL (articles + seen_urls)
   └── pipeline_runs → UPDATE (status='ok')
```

### Quality Scoring

The project has a scoring system to ensure that only fresh and relevant news has the highest chance of making it into the final digest.

| Signal | Score | Condition |
|---|---|---|
| Cross-source | +5 | Same story from 2+ source types |
| Priority source | +3 | Key blogs/accounts |
| Recency | +2 | Published < 24h ago |
| Twitter engagement | +1 to +5 | Tiered by likes/retweets |
| Reddit score | +1 to +5 | Tiered by upvotes |
| Duplicate | -10 | Same URL already seen |
| Already reported | -5 | URL in seen_urls (last 14 days) |

## Quick Start

### Prerequisites

Bare minimum:
- A small Linux server (VPS)
- At least one API key for Twitter or web search (optional but recommended)

For Twitter, I recommend using the affordable [twitterapi.io](http://twitterapi.io/?ref=dennybeus) service.
For web search, I use the free API from [tavily.com](https://app.tavily.com/home).

### Environment Variables Setup

All API keys are optional. The pipeline can work with whatever you have, but I strongly recommend adding the following to your `.env` file:
- `TWITTERAPI_IO_KEY`
- `TAVILY_API_KEY` (1,000 free tokens per month)
- `GITHUB_TOKEN` (bypasses rate limits)

And make sure to edit these fields:
- `POSTGRES_USER` (replace `user` at the end of multi_parser_user with your preferred username)
- `POSTGRES_PASSWORD` (set your own password)
- `DATABASE_URL` (replace multi_parser_user and changeme with your `POSTGRES_USER` and `POSTGRES_PASSWORD` respectively)

```bash
# =============================================================================
# Postgres — must match values in docker-compose.yml
# =============================================================================
POSTGRES_DB=multi_parser
POSTGRES_USER=multi_parser_user
POSTGRES_PASSWORD=changeme

# DATABASE_URL is derived from the three variables above:
# postgresql://<POSTGRES_USER>:<POSTGRES_PASSWORD>@127.0.0.1:5432/<POSTGRES_DB>
DATABASE_URL=postgresql://multi_parser_user:changeme@127.0.0.1:5432/multi_parser

# =============================================================================
# Twitter/X  (at least one recommended)
# =============================================================================
GETX_API_KEY=
TWITTERAPI_IO_KEY=
X_BEARER_TOKEN=

# =============================================================================
# Web search  (at least one recommended)
# =============================================================================
BRAVE_API_KEYS=
TAVILY_API_KEY=

# =============================================================================
# GitHub  (optional — improves rate limits)
# =============================================================================
GITHUB_TOKEN=
```

### Automated Setup (VPS / Linux)

To save you from running every command manually, I made a convenient one-shot setup script `run-setup.sh` that will handle the following for you:

1. Install `python3-pip`, `docker.io`, `docker-compose`, `apparmor`
2. Add the current user to the `docker` group
3. Install Python dependencies from `requirements.txt`
4. Start PostgreSQL 16 via Docker Compose
5. Apply database migrations
6. Validate config
7. Set up cron (05:00 and 17:00 UTC daily)

All you need to do is run the following commands:

```bash
# 1. Clone the repository
git clone git@github.com:DennyBeus/multi-parser.git
cd multi-parser

# 2. Configure environment variables
cp .env.example .env
nano .env    # at minimum, set POSTGRES_PASSWORD and DATABASE_URL

# 3. Run setup (installs deps, starts Postgres, applies migrations, sets up cron)
chmod +x run-setup.sh
./run-setup.sh
```

The script is idempotent, meaning it's safe to run multiple times.

### Manual Setup

You can also run all the commands yourself by following the setup guide in [SETUP.md](SETUP.md), but the `run-setup.sh` script mentioned above does exactly the same thing.

## Configuration

### Sources & Topics

- `config/defaults/sources.json` — 93 built-in sources (21 RSS, 45 Twitter, 19 GitHub, 8 Reddit) that you can add, remove, and edit directly through your agent or manually on the server.
- `config/defaults/topics.json` — topic definitions with search queries and filters. Currently there's only one topic, `ai`, but you can add new ones matching your interests through the same agent.
> You don't even need to restart the project — all changes take effect immediately since all scripts run exclusively via cron.

### Cron Schedule

Default: every 24 hours (06:00 UTC). Edit in `run-setup.sh` before running:

```bash
CRON_SCHEDULE="0 6 * * *"
```

## Database

PostgreSQL 16 (Docker), 3 tables:

| Table | Purpose |
|---|---|
| `pipeline_runs` | Tracks each cron execution (timing, status, error) |
| `articles` | Merged/scored articles per run (UNIQUE on run_id + normalized_url) |
| `seen_urls` | Cross-run deduplication — replaces archive scanning |

Auto-cleanup: articles older than 90 days and seen_urls older than 180 days are removed after each pipeline run.

Memory tuning for 4GB RAM VPS is pre-configured in `docker-compose.yml` (256MB shared_buffers, 20 max connections).

## Project Structure

After the first pipeline run, a `/logs/` folder will be created in the project root where task statuses are recorded after each cron trigger. I intentionally placed this folder inside the project so the agent can easily locate the logs. This also keeps them separate from other programs' logs, which would be an issue with a system directory like `/tmp/`.

```
multi-parser/
├── agent-instructions/
│   └── digest-prompt.md          # Scheduled agent instructions (export → translate → deliver)
├── assets/
│   └── readme_image.jpg          # README image
├── config/
│   ├── defaults/
│   │   ├── sources.json          # 93 built-in sources
│   │   └── topics.json           # topic definitions & search queries
│   └── schema.json               # JSON Schema for config validation
├── cron/
│   └── run-parser.sh             # cron wrapper (every 24h)
├── db/
│   ├── migrate.py                # migration runner
│   └── migrations/
│       ├── 001_initial.sql       # core schema (3 tables + indexes)
│       └── 002_cleanup_retention.sql  # auto-cleanup function
├── scripts/
│   ├── run-pipeline.py           # main orchestrator (parallel fetch)
│   ├── run-pipeline-db.py        # DB wrapper (pipeline + storage)
│   ├── fetch-rss.py              # RSS/Atom feed fetcher
│   ├── fetch-twitter.py          # Twitter/X fetcher (3 backends)
│   ├── fetch-github.py           # GitHub releases + trending
│   ├── fetch-reddit.py           # Reddit public API
│   ├── fetch-web.py              # Brave/Tavily web search
│   ├── merge-sources.py          # dedup + quality scoring engine
│   ├── enrich-articles.py        # optional full-text enrichment
│   ├── store-merged.py           # JSON → PostgreSQL
│   ├── config_loader.py          # two-layer config overlay
│   ├── db_conn.py                # database connection helper
│   ├── cleanup-db.py             # manual DB cleanup
│   ├── source-health.py          # source availability checker
│   ├── validate-config.py        # config validation
│   └── delivery/                 # Output formatters (DB → digest)
│       ├── export-latest.py      # PostgreSQL → markdown
│       ├── generate-pdf.py       # markdown → PDF (Russian typesetting)
│       ├── sanitize-html.py      # HTML sanitizer
│       └── send-email.py         # Email delivery
├── tests/
│   ├── test_config.py
│   ├── test_db.py
│   ├── test_merge.py
│   └── fixtures/                 # sample data for each source type
├── docker-compose.yml            # PostgreSQL 16 + tuning
├── requirements.txt              # 5 dependencies + system libs
├── run-setup.sh                  # one-shot VPS setup
├── SETUP.md                      # step-by-step manual setup guide
├── LICENSE                       # project license
├── .env.example                  # environment template
└── .github/workflows/test.yml    # CI: Python 3.9 + 3.12
```

## Dependencies

Python packages (5):

```
feedparser>=6.0.0        # RSS/Atom parsing (falls back to regex without it)
jsonschema>=4.0.0        # config validation
psycopg2-binary>=2.9.0   # PostgreSQL driver
python-dotenv>=1.0.0     # .env file loading
weasyprint>=68.0         # PDF generation (delivery scripts)
```

System dependencies (for WeasyPrint):
```bash
sudo apt install fonts-noto-cjk libpango-1.0-0 libpangoft2-1.0-0 libpangocairo-1.0-0
```

See [SETUP.md](SETUP.md) for details.

## Tests

CI runs on Python 3.9 and 3.12 via GitHub Actions.

```bash
# All tests
python -m unittest discover -s tests -v

# Single file
python -m unittest tests/test_merge.py -v
python -m unittest tests/test_db.py -v
```

## Origin

Multi-Parser is a reworked fork of [draco-agent/tech-news-digest](https://github.com/draco-agent/tech-news-digest) that I turned into a cost-effective solution. Anyone can customize it to their needs or keep scaling the parser for their own AI agent.
