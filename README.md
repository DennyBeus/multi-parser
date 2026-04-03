# Multi-Parser

<p align="center">
  <strong>Deterministic tech news aggregator — cheap, accurate, zero LLM tokens in the pipeline.</strong>
</p>

<p align="center">
  <a href="https://github.com/DennyBeus/multi-parser/actions/workflows/test.yml?branch=main"><img src="https://img.shields.io/github/actions/workflow/status/DennyBeus/multi-parser/test.yml?branch=main&style=for-the-badge" alt="CI status"></a>
  <a href="https://github.com/DennyBeus/multi-parser/releases"><img src="https://img.shields.io/github/v/release/DennyBeus/multi-parser?include_prereleases&style=for-the-badge" alt="GitHub release"></a>
  <a href="https://img.shields.io/badge/python-3.8+-blue"><img src="https://img.shields.io/badge/python-3.8+-blue.svg?style=for-the-badge" alt="Python 3.8+"></a>
</p>

**English** | [Русский](README_RU.md)

## Why Multi-Parser?

Multi-Parser was built as a **cheap and deterministic replacement** for an AI agent's daily digest skill. Instead of burning LLM tokens on fetching, filtering, and deduplicating news, this pipeline does it all with pure Python — no LLM calls, no hallucinations, no wasted tokens.

**The parser and the agent work separately.** The pipeline writes structured data to Postgres; the agent reads from the database when it's time to compose a digest. This means zero extra token spend on data collection — the agent only uses tokens for the final summary and delivery.

> Agent configuration for working with this pipeline will be published in a separate repository.

## What It Does

Collects tech news from **93 sources** across 5 source types, scores and deduplicates them, and stores the result in PostgreSQL — ready for any downstream consumer.

| Source Type | Count | Examples |
|---|---|---|
| RSS | 21 feeds | Simon Willison, Hugging Face, OpenAI, The Verge AI, Ars Technica... |
| Twitter/X | 45 KOLs | @karpathy, @sama, @elonmusk, @VitalikButerin, @AndrewYNg... |
| GitHub | 19 repos | LangChain, vLLM, DeepSeek, Llama, Ollama, Open WebUI... |
| Reddit | 8 subs | r/MachineLearning, r/LocalLLaMA, r/artificial... |
| Web Search | topic-based | Brave Search or Tavily API with freshness filters |

## Pipeline

```
cron/run-digest.sh (every 12h)
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

| Signal | Score | Condition |
|---|---|---|
| Multi-source cross-ref | +5 | Same story from 2+ source types |
| Priority source | +3 | Key blogs/accounts |
| Recency | +2 | Published < 24h ago |
| Twitter engagement | +1 to +5 | Tiered by likes/retweets |
| Reddit score | +1 to +5 | Tiered by upvotes |
| Duplicate | -10 | Same URL seen |
| Already reported | -5 | URL in seen_urls (last 14 days) |

### Deduplication

Three-phase dedup: **URL normalization** → **title similarity** (0.75 threshold via SequenceMatcher with token-based bucketing) → **cross-topic dedup** (each article appears in one topic only). Domain limit: max 3 articles per domain per topic (exempt: x.com, github.com, reddit.com).

## Quick Start

### Prerequisites

- Python 3.8+
- Docker & Docker Compose (for PostgreSQL)
- At least one API key for Twitter or Web Search (optional but recommended)

### Automated Setup (VPS / Linux)

The `run-setup.sh` script handles everything in one run — ideal for a fresh VPS:

```bash
git clone https://github.com/DennyBeus/multi-parser.git
cd multi-parser

# 1. Configure environment
cp .env.example .env
nano .env    # set POSTGRES_PASSWORD and DATABASE_URL at minimum

# 2. Run setup (installs deps, starts Postgres, applies migrations, sets up cron)
chmod +x run-setup.sh
./run-setup.sh
```

The script is idempotent — safe to re-run. It will:
1. Install `python3-pip`, `docker.io`, `docker-compose`, `apparmor`
2. Add current user to the `docker` group
3. Install Python dependencies from `requirements.txt`
4. Start PostgreSQL 16 via Docker Compose
5. Apply database migrations
6. Validate config
7. Set up cron (05:00 and 17:00 UTC daily)

### Manual Setup

```bash
# Install dependencies
pip install -r requirements.txt

# Start PostgreSQL
docker-compose up -d

# Apply migrations
python db/migrate.py

# Validate config
python scripts/validate-config.py config/defaults

# Test run (JSON only, no DB)
python scripts/run-pipeline.py --only rss,github --output /tmp/test-digest.json

# Full run with DB storage
python scripts/run-pipeline-db.py --hours 48 --output /tmp/digest.json --verbose
```

## Environment Variables

All API keys are optional. The pipeline runs with whatever sources are available.

```bash
# PostgreSQL (required for DB mode)
POSTGRES_PASSWORD=your_password
DATABASE_URL=postgresql://multi_parser_user:your_password@127.0.0.1:5432/multi_parser

# Twitter/X — at least one recommended (auto priority: getxapi > twitterapiio > official)
GETX_API_KEY=
TWITTERAPI_IO_KEY=
X_BEARER_TOKEN=

# Web Search — at least one recommended (auto: brave > tavily)
BRAVE_API_KEYS=k1,k2,k3    # comma-separated for rotation
TAVILY_API_KEY=

# GitHub — optional, improves rate limits
GITHUB_TOKEN=
```

## Configuration

### Sources & Topics

- `config/defaults/sources.json` — 93 built-in sources (21 RSS, 45 Twitter, 19 GitHub, 8 Reddit)
- `config/defaults/topics.json` — topic definitions with search queries and keyword filters

User overrides in `workspace/config/` take priority. Your overlay **merges** with defaults:

```json
{
  "sources": [
    {"id": "my-blog", "type": "rss", "enabled": true, "url": "https://myblog.com/feed"},
    {"id": "openai-blog", "enabled": false}
  ]
}
```

- **Override** a source by matching its `id`
- **Add** new sources with a unique `id`
- **Disable** a built-in source with `"enabled": false`

### Cron Schedule

Default: every 12 hours (05:00 and 17:00 UTC). Change in `run-setup.sh` before running:

```bash
CRON_SCHEDULE="0 5,17 * * *"
```

## Database

PostgreSQL 16 (Docker) with 3 tables:

| Table | Purpose |
|---|---|
| `pipeline_runs` | Tracks each cron execution (timing, status, error) |
| `articles` | Merged/scored articles per run (UNIQUE on run_id + normalized_url) |
| `seen_urls` | Cross-run dedup — replaces archive scanning |

Auto-cleanup: articles older than 90 days and seen_urls older than 180 days are removed after each pipeline run.

Memory tuning for 4GB RAM VPS is pre-configured in `docker-compose.yml` (256MB shared_buffers, 20 max connections).

## Project Structure

```
multi-parser/
├── config/
│   ├── defaults/
│   │   ├── sources.json          # 93 built-in sources
│   │   └── topics.json           # topic definitions & search queries
│   └── schema.json               # JSON Schema for config validation
├── cron/
│   └── run-digest.sh             # cron wrapper (every 12h)
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
│   └── delivery/                 # Phase 2: output formatters
│       ├── generate-pdf.py
│       ├── sanitize-html.py
│       └── send-email.py
├── tests/
│   ├── test_config.py
│   ├── test_db.py
│   ├── test_merge.py
│   └── fixtures/                 # sample data for each source type
├── docker-compose.yml            # PostgreSQL 16 + tuning
├── requirements.txt              # 4 dependencies
├── run-setup.sh                  # one-shot VPS setup
├── .env.example                  # environment template
└── .github/workflows/test.yml    # CI: Python 3.9 + 3.12
```

## Dependencies

Minimal by design — 4 packages:

```
feedparser>=6.0.0        # RSS/Atom parsing (fallback to regex if missing)
jsonschema>=4.0.0        # config validation
psycopg2-binary>=2.9.0   # PostgreSQL driver
python-dotenv>=1.0.0     # .env file loading
```

## Running Individual Fetchers

Each fetch script works standalone:

```bash
python scripts/fetch-rss.py --defaults config/defaults --output rss.json
python scripts/fetch-twitter.py --defaults config/defaults --output twitter.json --hours 48
python scripts/fetch-github.py --defaults config/defaults --output github.json
python scripts/fetch-reddit.py --defaults config/defaults --output reddit.json
python scripts/fetch-web.py --defaults config/defaults --output web.json
```

## Tests

```bash
# All tests
python -m unittest discover -s tests -v

# Single test file
python -m unittest tests/test_merge.py -v
python -m unittest tests/test_db.py -v
```

CI runs on Python 3.9 and 3.12 via GitHub Actions.

## Origin

Forked from [draco-agent/tech-news-digest](https://github.com/draco-agent/tech-news-digest) and reworked: consolidated to a single AI topic, updated sources, added automated VPS setup, and adapted for use as a standalone data backend for an AI agent's daily digest workflow.
