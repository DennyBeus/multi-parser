-- 001_initial.sql
-- Core schema for multi-parser pipeline storage

CREATE TABLE pipeline_runs (
    id              SERIAL PRIMARY KEY,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    finished_at     TIMESTAMPTZ,
    status          TEXT NOT NULL DEFAULT 'running',
    hours_window    INTEGER NOT NULL DEFAULT 48,
    steps_summary   JSONB,
    total_merged    INTEGER DEFAULT 0,
    error_message   TEXT
);

CREATE TABLE articles (
    id              BIGSERIAL PRIMARY KEY,
    pipeline_run_id INTEGER NOT NULL REFERENCES pipeline_runs(id),
    title           TEXT NOT NULL,
    link            TEXT NOT NULL,
    normalized_url  TEXT NOT NULL,
    published_at    TIMESTAMPTZ,
    source_type     TEXT NOT NULL,
    source_id       TEXT,
    source_name     TEXT,
    primary_topic   TEXT,
    all_topics      TEXT[],
    quality_score   REAL NOT NULL DEFAULT 0,
    snippet         TEXT,
    metrics         JSONB,
    multi_source    BOOLEAN DEFAULT FALSE,
    source_count    INTEGER DEFAULT 1,
    all_sources     TEXT[],
    full_text       TEXT,
    full_text_method TEXT,
    in_previous_digest BOOLEAN DEFAULT FALSE,
    raw_json        JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(pipeline_run_id, normalized_url)
);

CREATE INDEX idx_articles_run ON articles(pipeline_run_id);
CREATE INDEX idx_articles_topic ON articles(primary_topic);
CREATE INDEX idx_articles_score ON articles(quality_score DESC);
CREATE INDEX idx_articles_published ON articles(published_at);
CREATE INDEX idx_articles_source_type ON articles(source_type);

CREATE TABLE seen_urls (
    normalized_url  TEXT PRIMARY KEY,
    first_seen_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    times_seen      INTEGER NOT NULL DEFAULT 1,
    best_title      TEXT
);
