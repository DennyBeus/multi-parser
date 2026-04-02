#!/usr/bin/env python3
"""
Pipeline wrapper that runs the fetch+merge pipeline and stores results in Postgres.

Wraps run-pipeline.py without modifying it:
1. Creates a pipeline_runs row (status='running')
2. Calls run-pipeline.py with forwarded arguments
3. Calls store-merged.py to persist results
4. Updates pipeline_runs with final status

Usage:
    python3 run-pipeline-db.py --hours 48 --output /tmp/td-merged.json --verbose
    python3 run-pipeline-db.py --enrich --freshness pd --verbose
"""

import json
import sys
import os
import subprocess
import time

from dotenv import load_dotenv
load_dotenv()
import argparse
import logging
from datetime import datetime, timezone
from pathlib import Path

SCRIPTS_DIR = Path(__file__).parent


def setup_logging(verbose: bool) -> logging.Logger:
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%H:%M:%S",
    )
    return logging.getLogger(__name__)


def get_db_conn():
    """Import and return a DB connection."""
    sys.path.insert(0, str(SCRIPTS_DIR))
    from db_conn import get_conn
    return get_conn()


def create_pipeline_run(conn, hours_window: int) -> int:
    """Insert a new pipeline_runs row and return its id."""
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO pipeline_runs (hours_window) VALUES (%s) RETURNING id",
            (hours_window,),
        )
        run_id = cur.fetchone()[0]
    conn.commit()
    return run_id


def update_pipeline_run(conn, run_id: int, status: str, total_merged: int = 0,
                        steps_summary: dict = None, error_message: str = None):
    """Update pipeline_runs row with final status."""
    with conn.cursor() as cur:
        cur.execute("""
            UPDATE pipeline_runs
            SET finished_at = NOW(), status = %s, total_merged = %s,
                steps_summary = %s, error_message = %s
            WHERE id = %s
        """, (
            status,
            total_merged,
            json.dumps(steps_summary) if steps_summary else None,
            error_message,
            run_id,
        ))
    conn.commit()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run multi-parser pipeline with Postgres storage.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    _script_dir = Path(__file__).resolve().parent
    _default_defaults = _script_dir.parent / "config" / "defaults"
    parser.add_argument("--defaults", type=Path, default=_default_defaults)
    parser.add_argument("--config", type=Path, default=None)
    parser.add_argument("--hours", type=int, default=48)
    parser.add_argument("--freshness", type=str, default="pd")
    parser.add_argument("--output", "-o", type=Path, default=Path("/tmp/td-merged.json"))
    parser.add_argument("--step-timeout", type=int, default=180)
    parser.add_argument("--twitter-backend", choices=["official", "twitterapiio", "auto"], default=None)
    parser.add_argument("--verbose", "-v", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--enrich", action="store_true")
    parser.add_argument("--skip", type=str, default="")
    parser.add_argument("--only", type=str, default="")
    parser.add_argument("--db-dedup", action="store_true", default=True,
                        help="Use Postgres seen_urls for cross-run dedup (default: on)")
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()

    logger = setup_logging(args.verbose)

    # Step 1: Create pipeline run in DB
    conn = get_db_conn()
    run_id = create_pipeline_run(conn, args.hours)
    logger.info(f"Pipeline run #{run_id} started")

    # Step 2: Build command for run-pipeline.py
    cmd = [
        sys.executable, str(SCRIPTS_DIR / "run-pipeline.py"),
        "--defaults", str(args.defaults),
        "--hours", str(args.hours),
        "--freshness", args.freshness,
        "--output", str(args.output),
        "--step-timeout", str(args.step_timeout),
    ]
    if args.config:
        cmd += ["--config", str(args.config)]
    if args.twitter_backend:
        cmd += ["--twitter-backend", args.twitter_backend]
    if args.verbose:
        cmd.append("--verbose")
    if args.force:
        cmd.append("--force")
    if args.enrich:
        cmd.append("--enrich")
    if args.skip:
        cmd += ["--skip", args.skip]
    if args.only:
        cmd += ["--only", args.only]
    if args.debug:
        cmd.append("--debug")
    if args.db_dedup:
        cmd += ["--db-dedup"]

    # Run the pipeline
    logger.info(f"Running pipeline: {' '.join(cmd[-6:])}")
    t0 = time.time()
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=600, env=os.environ)
        if args.verbose and result.stdout:
            for line in result.stdout.strip().split("\n"):
                logger.debug(f"  [pipeline] {line}")
        if result.stderr:
            for line in result.stderr.strip().split("\n"):
                if line.strip():
                    logger.info(f"  [pipeline] {line}")
    except subprocess.TimeoutExpired:
        update_pipeline_run(conn, run_id, "error", error_message="Pipeline timed out after 600s")
        conn.close()
        logger.error("Pipeline timed out")
        return 1

    elapsed = time.time() - t0

    if result.returncode != 0:
        error_msg = (result.stderr or "")[-500:]
        update_pipeline_run(conn, run_id, "error", error_message=error_msg)
        conn.close()
        logger.error(f"Pipeline failed (exit {result.returncode}) in {elapsed:.1f}s")
        return 1

    # Step 3: Read pipeline metadata for steps_summary
    steps_summary = None
    meta_path = args.output.with_suffix(".meta.json")
    if meta_path.exists():
        try:
            with open(meta_path) as f:
                meta = json.load(f)
            steps_summary = {
                s["name"]: {"status": s["status"], "count": s.get("count", 0)}
                for s in meta.get("steps", [])
            }
        except Exception:
            pass

    # Step 4: Store merged articles in Postgres
    total_merged = 0
    if args.output.exists():
        logger.info("Storing articles in Postgres...")
        store_cmd = [
            sys.executable, str(SCRIPTS_DIR / "store-merged.py"),
            "--input", str(args.output),
            "--pipeline-run-id", str(run_id),
        ]
        if args.verbose:
            store_cmd.append("--verbose")

        store_result = subprocess.run(store_cmd, capture_output=True, text=True, env=os.environ)
        if store_result.returncode != 0:
            logger.error(f"store-merged.py failed: {store_result.stderr}")
            update_pipeline_run(conn, run_id, "error",
                                steps_summary=steps_summary,
                                error_message=f"store-merged failed: {store_result.stderr[-300:]}")
            conn.close()
            return 1

        # Count articles stored
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*) FROM articles WHERE pipeline_run_id = %s", (run_id,))
                total_merged = cur.fetchone()[0]
        except Exception:
            pass

        if store_result.stderr:
            for line in store_result.stderr.strip().split("\n"):
                if line.strip():
                    logger.info(f"  [store] {line}")

    # Step 5: Mark run as successful
    update_pipeline_run(conn, run_id, "ok", total_merged=total_merged, steps_summary=steps_summary)
    conn.close()

    logger.info(f"Pipeline run #{run_id} completed: {total_merged} articles stored in {elapsed:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
