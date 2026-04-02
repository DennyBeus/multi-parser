#!/usr/bin/env python3
"""
Simple schema migration runner for multi-parser.

Reads SQL files from db/migrations/ in alphabetical order,
tracks applied migrations in a schema_migrations table.

Usage:
    python db/migrate.py
    python db/migrate.py --status    # show applied migrations
"""

import os
import sys
import argparse
from pathlib import Path

from dotenv import load_dotenv
load_dotenv()

try:
    import psycopg2
except ImportError:
    print("Error: psycopg2 is required. Install with: pip install psycopg2-binary", file=sys.stderr)
    sys.exit(1)

MIGRATIONS_DIR = Path(__file__).parent / "migrations"


def get_conn():
    url = os.environ.get("DATABASE_URL")
    if not url:
        print("Error: DATABASE_URL environment variable is not set", file=sys.stderr)
        sys.exit(1)
    return psycopg2.connect(url)


def ensure_migrations_table(conn):
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
                filename    TEXT PRIMARY KEY,
                applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        """)
    conn.commit()


def get_applied(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT filename FROM schema_migrations ORDER BY filename")
        return {row[0] for row in cur.fetchall()}


def get_pending(applied):
    if not MIGRATIONS_DIR.exists():
        return []
    files = sorted(f for f in MIGRATIONS_DIR.iterdir() if f.suffix == ".sql")
    return [f for f in files if f.name not in applied]


def apply_migration(conn, filepath):
    sql = filepath.read_text(encoding="utf-8")
    with conn.cursor() as cur:
        cur.execute(sql)
        cur.execute(
            "INSERT INTO schema_migrations (filename) VALUES (%s)",
            (filepath.name,),
        )
    conn.commit()


def show_status(conn):
    applied = get_applied(conn)
    pending = get_pending(applied)
    print(f"Applied: {len(applied)}")
    for name in sorted(applied):
        print(f"  [ok] {name}")
    print(f"Pending: {len(pending)}")
    for f in pending:
        print(f"  [ ] {f.name}")


def main():
    parser = argparse.ArgumentParser(description="Run database migrations")
    parser.add_argument("--status", action="store_true", help="Show migration status")
    args = parser.parse_args()

    conn = get_conn()
    try:
        ensure_migrations_table(conn)

        if args.status:
            show_status(conn)
            return

        applied = get_applied(conn)
        pending = get_pending(applied)

        if not pending:
            print("All migrations are up to date.")
            return

        for filepath in pending:
            print(f"Applying {filepath.name}...")
            try:
                apply_migration(conn, filepath)
                print(f"  Done.")
            except Exception as e:
                conn.rollback()
                print(f"  FAILED: {e}", file=sys.stderr)
                sys.exit(1)

        print(f"Applied {len(pending)} migration(s).")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
