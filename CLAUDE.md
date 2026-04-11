# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Multi-Parser is an automated tech news aggregation pipeline that collects articles from 5 source types (RSS, Twitter/X, GitHub releases + trending, Reddit, web search), applies quality scoring, deduplicates, and stores results in Postgres. Runs on VPS via cron — no LLM in the data pipeline. Python 3.8+, minimal dependencies.

## Commands

### Run tests
```bash
python -m unittest discover -s tests -v
```

### Run a single test file
```bash
python -m unittest tests/test_merge.py -v
python -m unittest tests/test_db.py -v
```

### Run full pipeline (JSON only, no DB)
```bash
python scripts/run-pipeline.py --output output/digest.json
```

### Run full pipeline with Postgres storage
```bash
python scripts/run-pipeline-db.py --hours 48 --output /tmp/td-merged.json --verbose
```

### Run specific pipeline steps
```bash
python scripts/run-pipeline.py --only rss,github --output output/digest.json
python scripts/run-pipeline.py --skip twitter,reddit --output output/digest.json
```

### Run individual fetch scripts standalone
```bash
python scripts/fetch-rss.py --defaults config/defaults --output rss.json
python scripts/fetch-twitter.py --defaults config/defaults --output twitter.json --hours 48
python scripts/fetch-github.py --defaults config/defaults --output github.json
python scripts/fetch-reddit.py --defaults config/defaults --output reddit.json
python scripts/fetch-web.py --defaults config/defaults --output web.json
```

### Export and generate deliverables
```bash
python scripts/delivery/export-latest.py --hours 24 --min-score 6 --top-n 100 --output /tmp/articles.md
python scripts/delivery/generate-pdf.py --input /tmp/articles.md --output /tmp/digest.pdf
```

### Database setup
```bash
docker-compose up -d                    # Start Postgres
python db/migrate.py                    # Apply schema migrations
python db/migrate.py --status           # Check migration status
```

### Validate config
```bash
python scripts/validate-config.py config/defaults
```

### Install dependencies
```bash
pip install -r requirements.txt
```

## Architecture

### Pipeline Flow (cron -> scripts -> Postgres)

`run-pipeline-db.py` wraps the original pipeline with DB storage:

```
  cron/run-parser.sh (every 24h)
        │
        ▼
  run-pipeline-db.py
    ├── INSERT pipeline_runs (status='running')
    ├── run-pipeline.py
    │     ├── fetch-rss.py  ──────┐
    │     ├── fetch-twitter.py ───┤
    │     ├── fetch-github.py ────┤ (parallel, ~30s)
    │     ├── fetch-github.py ────┤ (--trending)
    │     ├── fetch-reddit.py ────┤
    │     └── fetch-web.py ───────┘
    │              │
    │              ▼
    │     merge-sources.py (dedup + scoring + --db-dedup)
    │              │
    │              ▼
    │     enrich-articles.py (optional full-text)
    │              │
    │              ▼
    │     merged JSON
    ├── store-merged.py → Postgres (articles + seen_urls)
    └── UPDATE pipeline_runs (status='ok')
```

### Postgres Schema (3 tables)

- `pipeline_runs` — tracks each cron execution (timing, status, error)
- `articles` — merged/scored articles per run (UNIQUE on run_id + normalized_url)
- `seen_urls` — cross-run dedup (replaces archive dir scanning)

### Config System

Two-layer config overlay: defaults in `config/defaults/` are merged with optional user overrides from a workspace `config/` directory. User sources override defaults by matching `id`. Handled by `scripts/config_loader.py`.

- `config/defaults/sources.json` — 93 sources (21 RSS, 45 Twitter, 19 GitHub, 8 Reddit)
- `config/defaults/topics.json` — 1 topic: ai

### Quality Scoring (merge-sources.py)

Articles are scored by: priority source (+3), recency <24h (+2), Twitter engagement (tiered +1 to +5), Reddit score (tiered +1 to +5), multi-source cross-references (+5 per source type), duplicate penalty (-10), old report penalty (-5).

### Deduplication (merge-sources.py)

Three phases: URL normalization, title similarity (threshold 0.75 via SequenceMatcher with token-based bucketing), and cross-topic dedup (each article appears in one topic only).

Domain limits: max 3 articles per domain per topic (exempt: x.com, twitter.com, github.com, reddit.com).

Cross-run dedup: `--db-dedup` flag queries `seen_urls` table (last 14 days) instead of scanning archive `.md` files.

### Key Environment Variables

- **Postgres**: `DATABASE_URL` (required for DB pipeline mode)
- **Twitter**: `GETX_API_KEY`, `TWITTERAPI_IO_KEY`, `X_BEARER_TOKEN` (auto-selects best available)
- **Web search**: `BRAVE_API_KEYS` (comma-separated for rotation), `BRAVE_API_KEY`, `TAVILY_API_KEY`
- **GitHub**: `GITHUB_TOKEN` or GitHub App credentials (`GH_APP_ID`, `GH_APP_INSTALL_ID`, `GH_APP_KEY_FILE`)

### Each fetch script is independent

All scripts under `scripts/` can run standalone with their own CLI args or be orchestrated by `run-pipeline.py`. They share a common JSON output structure with `sources[]` containing `articles[]`.

### Agent Instructions

`agent-instructions/` contains scheduled agent prompts and workflows:

- `digest-prompt.md` — Instructions for the daily digest scheduled agent (exports articles from DB, translates to Russian, generates PDF, sends to Telegram).

### Delivery scripts

`scripts/delivery/` contains scripts for converting DB content into deliverables:

- `export-latest.py` — Exports articles from PostgreSQL as markdown (filters by hours, min_score, top_n, groups by source_type). Strips emoji from titles/snippets.
- `generate-pdf.py` — Converts markdown to PDF with Russian typesetting support (tuned fonts, margins, line-height for compact output).
- `send-email.py`, `sanitize-html.py` — Reserved for future email delivery pipeline.

Usage example (digest agent flow):
```bash
python3 export-latest.py --hours 24 --min-score 6 --top-n 100 --output /tmp/raw.md
python3 generate-pdf.py --input /tmp/raw.md --output /tmp/digest.pdf
```

### Test structure

Tests use Python `unittest` (no pytest). Test fixtures in `tests/fixtures/` provide sample JSON data for each source type. CI runs on Python 3.9 and 3.12.
