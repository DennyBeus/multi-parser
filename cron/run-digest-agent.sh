#!/bin/bash
# =============================================================================
# run-digest-agent.sh — daily digest agent for multi-parser
#
# Runs after run-parser.sh (pipeline). Exports articles from DB, then
# launches Claude agent which translates, generates PDF and sends to Telegram.
#
# Install in crontab (2 hours after pipeline, e.g. at 08:00 UTC):
#   0 8 * * * /path/to/multi-parser/cron/run-digest-agent.sh >> /path/to/multi-parser/logs/digest-agent.log 2>&1
#
# Required env vars (set in .env):
#   DATABASE_URL       — Postgres connection string
#   TELEGRAM_CHAT_ID   — Telegram chat/user ID to send digest to
#
# Claude Code CLI must be installed and authorized on the server (claude auth login)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
EXPORT_FILE="/tmp/digest-raw.md"
PROMPT_FILE="$SCRIPT_DIR/agent-instructions/digest-prompt.md"

# Source environment variables
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
    set +a
fi

mkdir -p "$LOG_DIR"

echo "=== Digest agent run $TIMESTAMP ==="

# Validate required env vars
if [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    echo "[fail] TELEGRAM_CHAT_ID is not set in .env — aborting"
    exit 1
fi
if [ -z "${DATABASE_URL:-}" ]; then
    echo "[fail] DATABASE_URL is not set in .env — aborting"
    exit 1
fi

# Export articles from DB → /tmp/digest-raw.md
echo "[..] Exporting articles from DB..."
cd "$SCRIPT_DIR"
python3 scripts/delivery/export-latest.py \
    --hours 24 \
    --min-score 6 \
    --top-n 100 \
    --output "$EXPORT_FILE"
echo "[ok] Export complete: $EXPORT_FILE"

# Launch Claude agent with Telegram plugin
echo "[..] Starting Claude digest agent..."
export MULTI_PARSER_DIR="$SCRIPT_DIR"

claude \
    --dangerously-skip-permissions \
    --channels plugin:telegram@claude-plugins-official \
    -p "$(cat "$PROMPT_FILE")"

echo "=== Digest agent finished ==="
