#!/usr/bin/env bash
# Agent Memory — One-Shot Setup
# Starts Redis + PostgreSQL (pgvector) containers, creates DB, applies schema.
# Safe to re-run — idempotent throughout.
#
# Usage: bash setup.sh [project_name]
#   project_name defaults to "myproject"

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PROJECT_NAME="${1:-myproject}"
PG_USER="postgres"
PG_PASS="agentmem"
PG_DB="${PROJECT_NAME}_agent_memory"
PG_PORT="${CORTEX_PG_PORT:-5432}"
REDIS_PORT="${CORTEX_REDIS_PORT:-6379}"
PG_CONTAINER="${CORTEX_PG_CONTAINER:-mem-postgres}"
REDIS_CONTAINER="${CORTEX_REDIS_CONTAINER:-mem-redis}"
STREAM_NAME="${PROJECT_NAME}:cortex:events"
CONSUMER_GROUP="cortex-agents"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------

GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
BLUE='\033[34m'
NC='\033[0m'

ok()   { printf "${GREEN}✓${NC} %s\n" "$1"; }
fail() { printf "${RED}✗${NC} %s\n" "$1"; }
info() { printf "${BLUE}→${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}!${NC} %s\n" "$1"; }

# ---------------------------------------------------------------------------
# Container runtime detection
# ---------------------------------------------------------------------------

detect_runtime() {
    if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
        echo "podman"
    elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        echo "docker"
    else
        echo "none"
    fi
}

RUNTIME="$(detect_runtime)"

if [ "${RUNTIME}" = "none" ]; then
    fail "No container runtime found. Install Podman or Docker first."
    echo ""
    echo "  macOS:   brew install podman && podman machine init && podman machine start"
    echo "  Linux:   sudo apt install podman   (or docker.io)"
    echo "  Windows: Install Docker Desktop or Podman Desktop"
    echo ""
    exit 1
fi

ok "Container runtime: ${RUNTIME}"

# ---------------------------------------------------------------------------
# Start Redis container
# ---------------------------------------------------------------------------

info "Setting up Redis..."

if "${RUNTIME}" ps --format '{{.Names}}' 2>/dev/null | grep -q "^${REDIS_CONTAINER}$"; then
    ok "Redis container '${REDIS_CONTAINER}' already running"
elif "${RUNTIME}" ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${REDIS_CONTAINER}$"; then
    info "Starting existing Redis container..."
    "${RUNTIME}" start "${REDIS_CONTAINER}" >/dev/null 2>&1
    ok "Redis container started"
else
    info "Creating Redis container..."
    "${RUNTIME}" run -d \
        --name "${REDIS_CONTAINER}" \
        -p "${REDIS_PORT}:6379" \
        --restart unless-stopped \
        redis:7-alpine \
        redis-server --appendonly yes >/dev/null 2>&1
    ok "Redis container created and running on port ${REDIS_PORT}"
fi

# ---------------------------------------------------------------------------
# Start PostgreSQL (pgvector) container
# ---------------------------------------------------------------------------

info "Setting up PostgreSQL + pgvector..."

if "${RUNTIME}" ps --format '{{.Names}}' 2>/dev/null | grep -q "^${PG_CONTAINER}$"; then
    ok "PostgreSQL container '${PG_CONTAINER}' already running"
elif "${RUNTIME}" ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${PG_CONTAINER}$"; then
    info "Starting existing PostgreSQL container..."
    "${RUNTIME}" start "${PG_CONTAINER}" >/dev/null 2>&1
    ok "PostgreSQL container started"
else
    info "Creating PostgreSQL + pgvector container..."
    "${RUNTIME}" run -d \
        --name "${PG_CONTAINER}" \
        -p "${PG_PORT}:5432" \
        -e POSTGRES_PASSWORD="${PG_PASS}" \
        --restart unless-stopped \
        pgvector/pgvector:pg17 >/dev/null 2>&1

    # Wait for PostgreSQL to be ready
    info "Waiting for PostgreSQL to start..."
    for i in $(seq 1 30); do
        if "${RUNTIME}" exec "${PG_CONTAINER}" pg_isready -U "${PG_USER}" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    ok "PostgreSQL container created and running on port ${PG_PORT}"
fi

# ---------------------------------------------------------------------------
# Create database
# ---------------------------------------------------------------------------

info "Creating database '${PG_DB}'..."

DB_EXISTS=$("${RUNTIME}" exec "${PG_CONTAINER}" \
    psql -U "${PG_USER}" -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '${PG_DB}'" 2>/dev/null || true)

if [ "${DB_EXISTS}" = "1" ]; then
    ok "Database '${PG_DB}' already exists"
else
    "${RUNTIME}" exec "${PG_CONTAINER}" \
        psql -U "${PG_USER}" -c "CREATE DATABASE ${PG_DB};" >/dev/null 2>&1
    ok "Database '${PG_DB}' created"
fi

# ---------------------------------------------------------------------------
# Apply schema
# ---------------------------------------------------------------------------

info "Applying schema..."

"${RUNTIME}" cp "${SCRIPT_DIR}/schema.sql" "${PG_CONTAINER}:/tmp/schema.sql"
"${RUNTIME}" exec "${PG_CONTAINER}" \
    psql -U "${PG_USER}" -d "${PG_DB}" -f /tmp/schema.sql >/dev/null 2>&1

ok "Schema applied (16 tables + indexes)"

# ---------------------------------------------------------------------------
# Add project column to agents table (for multi-project support)
# ---------------------------------------------------------------------------

"${RUNTIME}" exec "${PG_CONTAINER}" \
    psql -U "${PG_USER}" -d "${PG_DB}" -c \
    "ALTER TABLE agents ADD COLUMN IF NOT EXISTS project TEXT DEFAULT '${PROJECT_NAME}';" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Setup Redis Stream + consumer group
# ---------------------------------------------------------------------------

info "Setting up Redis Stream..."

if command -v redis-cli >/dev/null 2>&1; then
    redis-cli -p "${REDIS_PORT}" XGROUP CREATE "${STREAM_NAME}" "${CONSUMER_GROUP}" "0" MKSTREAM >/dev/null 2>&1 || true
    ok "Redis Stream '${STREAM_NAME}' with consumer group '${CONSUMER_GROUP}'"
else
    warn "redis-cli not found — stream will be created on first use"
    echo "  Install: brew install redis (macOS) or apt install redis-tools (Linux)"
fi

# ---------------------------------------------------------------------------
# Make scripts executable
# ---------------------------------------------------------------------------

if [ -d "${SCRIPT_DIR}/scripts" ]; then
    chmod +x "${SCRIPT_DIR}/scripts/"* 2>/dev/null || true
    ok "Scripts marked executable"
fi

# ---------------------------------------------------------------------------
# Write .env file for reference
# ---------------------------------------------------------------------------

cat > "${SCRIPT_DIR}/.env" << ENVEOF
# Agent Memory — Environment Configuration
# Source this or export these variables before running cortex-* scripts.
export CORTEX_PROJECT="${PROJECT_NAME}"
export PG_PORT="${PG_PORT}"
export PG_USER="${PG_USER}"
export PG_PASS="${PG_PASS}"
export PG_DB="${PG_DB}"
export REDIS_PORT="${REDIS_PORT}"
export PG_CONTAINER="${PG_CONTAINER}"
export REDIS_CONTAINER="${REDIS_CONTAINER}"
# Optional: for semantic search (pgvector embeddings)
# export OPENROUTER_API_KEY="your-key-here"
ENVEOF

ok "Environment config written to .env"

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

echo ""
info "Verifying setup..."

# Check PostgreSQL
TABLE_COUNT=$("${RUNTIME}" exec "${PG_CONTAINER}" \
    psql -U "${PG_USER}" -d "${PG_DB}" -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'" 2>/dev/null || echo "0")
TABLE_COUNT=$(echo "${TABLE_COUNT}" | tr -d '[:space:]')

if [ "${TABLE_COUNT}" -ge 10 ]; then
    ok "PostgreSQL: ${TABLE_COUNT} tables verified"
else
    fail "PostgreSQL: expected ≥10 tables, found ${TABLE_COUNT}"
fi

# Check Redis
if command -v redis-cli >/dev/null 2>&1; then
    PONG=$(redis-cli -p "${REDIS_PORT}" PING 2>/dev/null || echo "FAIL")
    if [ "${PONG}" = "PONG" ]; then
        ok "Redis: connected"
    else
        fail "Redis: not responding"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "${GREEN}Agent Memory setup complete!${NC}\n"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Project:    ${PROJECT_NAME}"
echo "  Database:   ${PG_DB} (port ${PG_PORT})"
echo "  Redis:      localhost:${REDIS_PORT}"
echo "  Stream:     ${STREAM_NAME}"
echo ""
echo "  Next steps:"
echo "    1. source .env"
echo "    2. bash scripts/cortex-bootstrap <agent_name>"
echo ""
echo "  Example:"
echo "    source .env && bash scripts/cortex-bootstrap phoenix"
echo ""
