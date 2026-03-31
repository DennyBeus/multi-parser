#!/usr/bin/env python3
"""
Delete articles and pipeline_runs older than --retention-days (default: 30).
seen_urls are kept for 2x that period to preserve cross-run dedup coverage.

Usage:
    python3 scripts/cleanup-db.py
    python3 scripts/cleanup-db.py --retention-days 30
    python3 scripts/cleanup-db.py --dry-run
"""

import sys
import os
import argparse
from pathlib import Path

from dotenv import load_dotenv
load_dotenv()

SCRIPTS_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPTS_DIR))


def get_db_conn():
    from db_conn import get_conn
    return get_conn()


def run_cleanup(retention_days: int, dry_run: bool = False) -> dict:
    conn = get_db_conn()
    try:
        if dry_run:
            cutoff = f"NOW() - INTERVAL '{retention_days} days'"
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT COUNT(*) FROM articles WHERE created_at < NOW() - (%s || ' days')::INTERVAL",
                    (retention_days,)
                )
                articles = cur.fetchone()[0]
                cur.execute(
                    """SELECT COUNT(*) FROM pipeline_runs
                       WHERE started_at < NOW() - (%s || ' days')::INTERVAL
                         AND status IN ('ok', 'error')
                         AND NOT EXISTS (
                             SELECT 1 FROM articles WHERE pipeline_run_id = pipeline_runs.id
                         )""",
                    (retention_days,)
                )
                runs = cur.fetchone()[0]
                cur.execute(
                    "SELECT COUNT(*) FROM seen_urls WHERE last_seen_at < NOW() - (%s || ' days')::INTERVAL",
                    (retention_days * 2,)
                )
                seen_urls = cur.fetchone()[0]
            return {"articles": articles, "runs": runs, "seen_urls": seen_urls, "dry_run": True}

        with conn.cursor() as cur:
            cur.execute("SELECT * FROM cleanup_old_articles(%s)", (retention_days,))
            row = cur.fetchone()
        conn.commit()
        return {
            "articles": row[0],
            "runs": row[1],
            "seen_urls": row[2],
            "dry_run": False,
        }
    finally:
        conn.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Delete old articles from the database.")
    parser.add_argument(
        "--retention-days", type=int, default=30,
        help="Keep articles newer than this many days (default: 30). seen_urls kept for 2x."
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Show how many rows would be deleted without deleting anything."
    )
    args = parser.parse_args()

    result = run_cleanup(args.retention_days, dry_run=args.dry_run)

    prefix = "[dry-run] would delete" if result["dry_run"] else "Deleted"
    print(f"{prefix} {result['articles']} articles")
    print(f"{prefix} {result['runs']} pipeline runs")
    print(f"{prefix} {result['seen_urls']} seen_urls (older than {args.retention_days * 2} days)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
