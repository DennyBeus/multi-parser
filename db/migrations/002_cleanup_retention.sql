-- 002_cleanup_retention.sql
-- Add cleanup function for retention policy (default: 30 days for articles, 60 days for seen_urls)

CREATE OR REPLACE FUNCTION cleanup_old_articles(retention_days INT DEFAULT 30)
RETURNS TABLE(deleted_articles BIGINT, deleted_runs BIGINT, deleted_seen_urls BIGINT) AS $$
DECLARE
    cutoff_articles TIMESTAMPTZ;
    cutoff_seen_urls TIMESTAMPTZ;
    cnt_articles BIGINT;
    cnt_runs BIGINT;
    cnt_seen_urls BIGINT;
BEGIN
    cutoff_articles  := NOW() - (retention_days || ' days')::INTERVAL;
    cutoff_seen_urls := NOW() - ((retention_days * 2) || ' days')::INTERVAL;

    -- Delete articles older than cutoff
    DELETE FROM articles WHERE created_at < cutoff_articles;
    GET DIAGNOSTICS cnt_articles = ROW_COUNT;

    -- Delete orphaned pipeline_runs (finished, no remaining articles)
    DELETE FROM pipeline_runs
    WHERE started_at < cutoff_articles
      AND status IN ('ok', 'error')
      AND NOT EXISTS (
          SELECT 1 FROM articles WHERE pipeline_run_id = pipeline_runs.id
      );
    GET DIAGNOSTICS cnt_runs = ROW_COUNT;

    -- Delete old seen_urls (keep 2x longer than articles for better dedup coverage)
    DELETE FROM seen_urls WHERE last_seen_at < cutoff_seen_urls;
    GET DIAGNOSTICS cnt_seen_urls = ROW_COUNT;

    RETURN QUERY SELECT cnt_articles, cnt_runs, cnt_seen_urls;
END;
$$ LANGUAGE plpgsql;
