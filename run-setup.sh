#!/bin/bash
# =============================================================================
# run-setup.sh — one-shot setup for multi-parser on a fresh VPS
#
# Usage:
#   chmod +x run-setup.sh
#   ./run-setup.sh
#
# What it does:
#   1. Installs system packages (pip, docker.io) — requires sudo
#   2. Installs Python dependencies from requirements.txt
#   3. Starts PostgreSQL via docker-compose
#   4. Applies DB migrations
#   5. Validates config
#   6. Sets up cron job (every 12h at 05:00 and 17:00)
#
# Prerequisites:
#   - Fill in .env before running (copy from .env.example, then edit)
#   - Python 3.8+ already installed on the system
# =============================================================================
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# USER-ADJUSTABLE SETTINGS
# Change these if you want a different cron schedule or log retention.
# ─────────────────────────────────────────────────────────────────────────────

# Cron schedule for the digest pipeline (default: 05:00 and 17:00 every day)
CRON_SCHEDULE="0 5,17 * * *"

# ─────────────────────────────────────────────────────────────────────────────
# Internals — do not edit below this line
# ─────────────────────────────────────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRON_SCRIPT="$PROJECT_DIR/cron/run-digest.sh"
LOG_DIR="$PROJECT_DIR/logs"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[ok]${NC} $*"; }
info() { echo -e "${CYAN}[..] $*${NC}"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
fail() { echo -e "${RED}[fail]${NC} $*"; exit 1; }

echo ""
echo "=========================================="
echo "  multi-parser setup"
echo "  project dir: $PROJECT_DIR"
echo "=========================================="
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 0. Preflight checks
# ─────────────────────────────────────────────────────────────────────────────

info "Checking Python 3..."
if ! command -v python3 &>/dev/null; then
    fail "python3 not found. Install Python 3.8+ first."
fi
PYTHON_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
ok "Python $PYTHON_VERSION found"

info "Checking .env file..."
if [ ! -f "$PROJECT_DIR/.env" ]; then
    warn ".env not found — copying from .env.example"
    cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
    echo ""
    echo -e "${YELLOW}  IMPORTANT: Edit .env before continuing and fill in at least:${NC}"
    echo "    - POSTGRES_PASSWORD"
    echo "    - DATABASE_URL (update password to match)"
    echo "    - API keys you have (GitHub, Twitter/X, web search)"
    echo ""
    read -r -p "  Press Enter after you have saved .env to continue..."
    echo ""
fi

# Load .env so we can validate DATABASE_URL below
set -a
# shellcheck disable=SC1091
source "$PROJECT_DIR/.env"
set +a

if [ -z "${POSTGRES_PASSWORD:-}" ]; then
    fail "POSTGRES_PASSWORD is empty in .env. Set it and re-run."
fi
if [ -z "${DATABASE_URL:-}" ]; then
    fail "DATABASE_URL is empty in .env. Set it and re-run."
fi
ok ".env looks good"

# ─────────────────────────────────────────────────────────────────────────────
# 1. System packages (pip + docker)
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Step 1/6 — system packages"

install_with_sudo() {
    local pkg=$1
    if command -v sudo &>/dev/null; then
        sudo apt-get install -y "$pkg"
    else
        warn "sudo not available — trying apt-get as current user"
        apt-get install -y "$pkg" || fail "Cannot install $pkg. Run as root or install manually."
    fi
}

if ! command -v pip3 &>/dev/null; then
    info "Installing pip..."
    install_with_sudo python3-pip
    ok "pip installed"
else
    ok "pip3 already installed"
fi

if ! command -v docker &>/dev/null; then
    info "Installing docker.io + apparmor..."
    install_with_sudo docker.io
    install_with_sudo docker-compose
    install_with_sudo apparmor

    CURRENT_USER=$(whoami)
    info "Adding $CURRENT_USER to docker group..."
    if command -v sudo &>/dev/null; then
        sudo usermod -aG docker "$CURRENT_USER"
    else
        usermod -aG docker "$CURRENT_USER" || warn "Could not add to docker group — you may need to run: sudo usermod -aG docker $CURRENT_USER"
    fi

    echo ""
    warn "Docker was just installed. Group changes require a new session."
    warn "Running 'newgrp docker' to activate in this shell..."
    echo ""
    # Re-exec this script under the docker group so docker commands work immediately
    exec newgrp docker <<NEWGRP
        cd "$PROJECT_DIR"
        bash "$PROJECT_DIR/run-setup.sh" --skip-system-install
NEWGRP
else
    ok "docker already installed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Python dependencies
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Step 2/6 — Python dependencies"

cd "$PROJECT_DIR"

# Try normal install; fall back to --break-system-packages on Debian 12+
if pip3 install -r requirements.txt --quiet 2>/dev/null; then
    ok "Python dependencies installed"
else
    warn "Standard pip install failed (likely 'externally managed' on Debian 12+). Retrying with --break-system-packages..."
    pip3 install --break-system-packages -r requirements.txt --quiet
    ok "Python dependencies installed (--break-system-packages)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Start PostgreSQL
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Step 3/6 — starting PostgreSQL"

cd "$PROJECT_DIR"

# Check if docker-compose (v1 plugin syntax) or docker compose (v2) is available
if command -v docker-compose &>/dev/null; then
    DC="docker-compose"
elif docker compose version &>/dev/null 2>&1; then
    DC="docker compose"
else
    fail "Neither 'docker-compose' nor 'docker compose' found. Install docker-compose and retry."
fi

$DC up -d

# Wait for healthcheck to pass (up to 60s)
info "Waiting for Postgres to be ready..."
for i in $(seq 1 30); do
    STATUS=$($DC ps --format json 2>/dev/null | python3 -c "
import sys, json
rows = [json.loads(l) for l in sys.stdin if l.strip()]
for r in rows:
    if 'postgres' in r.get('Service','').lower() or 'postgres' in r.get('Name','').lower():
        print(r.get('Health', r.get('State', 'unknown')))
        sys.exit(0)
print('unknown')
" 2>/dev/null || echo "unknown")

    if echo "$STATUS" | grep -qi "healthy"; then
        ok "Postgres is healthy"
        break
    fi
    if [ "$i" -eq 30 ]; then
        warn "Postgres healthcheck not yet 'healthy' after 60s — check with: $DC ps"
    fi
    sleep 2
done

# ─────────────────────────────────────────────────────────────────────────────
# 4. Apply DB migrations
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Step 4/6 — applying DB migrations"

cd "$PROJECT_DIR"
python3 db/migrate.py
ok "Migrations applied"

python3 db/migrate.py --status

# ─────────────────────────────────────────────────────────────────────────────
# 5. Validate config
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Step 5/6 — validating config"

cd "$PROJECT_DIR"
python3 scripts/validate-config.py config/defaults
ok "Config valid"

# ─────────────────────────────────────────────────────────────────────────────
# 6. Set up cron
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Step 6/6 — setting up cron job"

chmod +x "$CRON_SCRIPT"
mkdir -p "$LOG_DIR"

CRON_LINE="$CRON_SCHEDULE $CRON_SCRIPT >> $LOG_DIR/cron.log 2>&1"

# Add only if not already present (avoid duplicates on re-run)
if crontab -l 2>/dev/null | grep -qF "$CRON_SCRIPT"; then
    ok "Cron job already present — skipping"
else
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    ok "Cron job added: $CRON_LINE"
fi

echo ""
echo "Current crontab:"
crontab -l

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo -e "  ${GREEN}Setup complete!${NC}"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Make sure .env has all your API keys filled in"
echo "  2. Test pipeline (no DB, fast):"
echo "     cd $PROJECT_DIR && python3 scripts/run-pipeline.py --only rss,github --output /tmp/test-digest.json"
echo "  3. Test full pipeline with DB:"
echo "     cd $PROJECT_DIR && python3 scripts/run-pipeline-db.py --hours 48 --output /tmp/td-merged.json --verbose"
echo "  4. Cron will run automatically at 05:00 and 17:00 UTC"
echo "     Logs: $LOG_DIR/cron.log"
echo ""
