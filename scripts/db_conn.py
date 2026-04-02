#!/usr/bin/env python3
"""
Shared Postgres connection helper for multi-parser.

Reads DATABASE_URL from environment. Used by store-merged.py,
run-pipeline-db.py, and merge-sources.py (--db-dedup).
"""

import os
import sys

from dotenv import load_dotenv
load_dotenv()

try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    print("Error: psycopg2 is required. Install with: pip install psycopg2-binary", file=sys.stderr)
    sys.exit(1)


def get_conn():
    """Return a psycopg2 connection using DATABASE_URL from environment."""
    url = os.environ.get("DATABASE_URL")
    if not url:
        raise RuntimeError("DATABASE_URL environment variable is not set")
    return psycopg2.connect(url)
