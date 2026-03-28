#!/bin/bash
# Cron wrapper for tech-news-digest pipeline with Postgres storage.
#
# Install in crontab:
#   0 8,20 * * * /home/denis/deploy/tech-news-digest/cron/run-digest.sh >> /home/denis/deploy/tech-news-digest/logs/cron.log 2>&1
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Source environment variables
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

mkdir -p "$LOG_DIR"

echo "=== Pipeline run $TIMESTAMP ==="

cd "$SCRIPT_DIR"

python3 scripts/run-pipeline-db.py \
    --defaults config/defaults \
    --hours 48 \
    --freshness pd \
    --output "/tmp/td-merged-${TIMESTAMP}.json" \
    --enrich \
    --verbose \
    2>&1 | tee "$LOG_DIR/run-${TIMESTAMP}.log"

EXIT_CODE=${PIPESTATUS[0]}

# Cleanup old files
find /tmp -name "td-merged-*.json" -mtime +7 -delete 2>/dev/null || true
find /tmp -name "td-merged-*.meta.json" -mtime +7 -delete 2>/dev/null || true
find "$LOG_DIR" -name "run-*.log" -mtime +30 -delete 2>/dev/null || true

echo "=== Finished with exit code $EXIT_CODE ==="
exit $EXIT_CODE
