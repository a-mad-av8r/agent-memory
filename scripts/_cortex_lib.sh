#!/usr/bin/env bash
# Agent Cortex shared library
# Replaces _lib.sh — adds PostgreSQL helpers, Redis Streams support, project scoping.
# Source this file: source "$(dirname "$0")/_cortex_lib.sh"

set -euo pipefail

# ---------------------------------------------------------------------------
# Directory resolution
# ---------------------------------------------------------------------------

# Resolve AGENTS_DIR to the .agents/ directory (parent of scripts/)
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MEMORY_DIR="${AGENTS_DIR}/memory"
SCRIPTS_DIR="${AGENTS_DIR}/scripts"

# ---------------------------------------------------------------------------
# Project scoping
# Prevents key/table collisions when multiple projects share the same store.
# ---------------------------------------------------------------------------

CORTEX_PROJECT="${CORTEX_PROJECT:-myproject}"
CORTEX_KEY_PREFIX="${CORTEX_KEY_PREFIX:-${CORTEX_PROJECT}:}"

# ---------------------------------------------------------------------------
# Redis config
# ---------------------------------------------------------------------------

REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_CONTAINER="mem-redis"

# ---------------------------------------------------------------------------
# PostgreSQL config
# ---------------------------------------------------------------------------

PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-postgres}"
PG_PASS="${PG_PASS:-agentmem}"
PG_DB="${PG_DB:-myproject_agent_memory}"
PG_CONTAINER="mem-postgres"

# ---------------------------------------------------------------------------
# Redis Streams config
# ---------------------------------------------------------------------------

CORTEX_STREAM="${CORTEX_KEY_PREFIX}cortex:events"
CORTEX_GROUP="cortex-agents"

# ---------------------------------------------------------------------------
# Container runtime detection
# Prefer podman over docker (Apple Silicon Mac).
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

# Cache the runtime so we only detect once per session
RUNTIME="${RUNTIME:-$(detect_runtime)}"

# ---------------------------------------------------------------------------
# Redis availability
# ---------------------------------------------------------------------------

redis_available() {
    if command -v redis-cli >/dev/null 2>&1; then
        redis-cli -p "${REDIS_PORT}" ping >/dev/null 2>&1
    else
        # Fallback: netcat probe
        (echo PING | nc -w 1 localhost "${REDIS_PORT}" 2>/dev/null | grep -q PONG) 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# rcli — raw Redis CLI wrapper
# Returns 0 on success, 1 on error. Errors go to stderr.
# ---------------------------------------------------------------------------

rcli() {
    if ! command -v redis-cli >/dev/null 2>&1; then
        echo "ERROR: redis-cli not found. Install redis-tools or use file fallback." >&2
        return 1
    fi
    local output
    output=$(redis-cli -p "${REDIS_PORT}" "$@" 2>&1)
    local rc=$?
    # Redis errors start with ERR, WRONGTYPE, NOSCRIPT, etc.
    if [ "${rc}" -ne 0 ] || [[ "${output}" == ERR* ]] || [[ "${output}" == WRONGTYPE* ]]; then
        echo "${output}" >&2
        return 1
    fi
    echo "${output}"
    return 0
}

# ---------------------------------------------------------------------------
# prcli — project-scoped Redis CLI
# Automatically prefixes the first key argument so that all key operations
# are isolated to the current CORTEX_PROJECT.
#
# Stream commands (XADD, XLEN, XRANGE, XREVRANGE, XREAD, XTRIM, etc.) are
# passed through without prefixing because the stream name is already fully
# qualified (set to "${CORTEX_KEY_PREFIX}cortex:events").
#
# Usage:
#   prcli GET "agents:state:sprints"
#       => GET "${CORTEX_KEY_PREFIX}agents:state:sprints"
#   prcli XADD "${CORTEX_STREAM}" "*" type start agent sophia ...
#       => XADD (stream name passed as-is)
# ---------------------------------------------------------------------------

prcli() {
    local cmd="$1"
    shift
    case "${cmd}" in
        # Single-key commands — prefix first arg
        GET|SET|DEL|EXISTS|TTL|EXPIRE|TYPE|INCR|DECR)
            local key="${CORTEX_KEY_PREFIX}$1"; shift
            rcli "${cmd}" "${key}" "$@"
            ;;
        # Hash commands — prefix the key (first arg); rest are field/value pairs
        HSET|HGET|HGETALL|HDEL|HEXISTS|HLEN|HKEYS|HVALS|HMGET)
            local key="${CORTEX_KEY_PREFIX}$1"; shift
            rcli "${cmd}" "${key}" "$@"
            ;;
        # Sorted set commands — prefix first arg
        ZADD|ZRANGE|ZRANGEBYSCORE|ZREM|ZSCORE|ZCARD|ZRANK)
            local key="${CORTEX_KEY_PREFIX}$1"; shift
            rcli "${cmd}" "${key}" "$@"
            ;;
        # List commands — prefix first arg
        LLEN|LRANGE|RPUSH|LREM|LPUSH|LPOP|RPOP|LINDEX)
            local key="${CORTEX_KEY_PREFIX}$1"; shift
            rcli "${cmd}" "${key}" "$@"
            ;;
        # Pattern commands — prefix the pattern
        KEYS)
            local pattern="${CORTEX_KEY_PREFIX}$1"; shift
            rcli "${cmd}" "${pattern}" "$@"
            ;;
        # Stream commands — pass through without prefixing (name is already qualified)
        XADD|XLEN|XRANGE|XREVRANGE|XREAD|XTRIM|XGROUP|XREADGROUP|XACK|XPENDING|XDEL)
            rcli "${cmd}" "$@"
            ;;
        # Everything else — pass through (PING, INFO, CONFIG, etc.)
        *)
            rcli "${cmd}" "$@"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# PostgreSQL helpers
# ---------------------------------------------------------------------------

# pg_available — returns 0 if PostgreSQL is reachable
pg_available() {
    if [ "${RUNTIME}" != "none" ]; then
        "${RUNTIME}" exec "${PG_CONTAINER}" \
            psql -U "${PG_USER}" -d "${PG_DB}" -c "SELECT 1" >/dev/null 2>&1
    else
        PGPASSWORD="${PG_PASS}" psql \
            -h localhost -p "${PG_PORT}" \
            -U "${PG_USER}" -d "${PG_DB}" \
            -c "SELECT 1" >/dev/null 2>&1
    fi
}

# pg_query — run a SELECT and print results with no headers, pipe-delimited
# Usage: pg_query "SELECT id, name FROM agents WHERE project = 'tam'"
pg_query() {
    local sql="$1"
    if [ "${RUNTIME}" != "none" ]; then
        "${RUNTIME}" exec "${PG_CONTAINER}" \
            psql -U "${PG_USER}" -d "${PG_DB}" \
            -t -A -F '|' \
            -c "${sql}"
    else
        PGPASSWORD="${PG_PASS}" psql \
            -h localhost -p "${PG_PORT}" \
            -U "${PG_USER}" -d "${PG_DB}" \
            -t -A -F '|' \
            -c "${sql}"
    fi
}

# pg_exec — run an INSERT/UPDATE/DELETE (output suppressed)
# Usage: pg_exec "INSERT INTO events (type, agent) VALUES ('start', 'sophia')"
pg_exec() {
    local sql="$1"
    if [ "${RUNTIME}" != "none" ]; then
        "${RUNTIME}" exec "${PG_CONTAINER}" \
            psql -U "${PG_USER}" -d "${PG_DB}" \
            -c "${sql}" >/dev/null
    else
        PGPASSWORD="${PG_PASS}" psql \
            -h localhost -p "${PG_PORT}" \
            -U "${PG_USER}" -d "${PG_DB}" \
            -c "${sql}" >/dev/null
    fi
}

# sql_escape — escape single quotes for safe SQL string interpolation
# Usage: val=$(sql_escape "O'Brien")
sql_escape() {
    local raw="$1"
    # Replace each ' with ''
    printf '%s' "${raw//\'/\'\'}"
}

# ---------------------------------------------------------------------------
# Redis Streams helpers
# ---------------------------------------------------------------------------

# cortex_ensure_stream — idempotent stream + consumer group creation
# Safe to call multiple times; errors from XGROUP CREATE are suppressed.
cortex_ensure_stream() {
    rcli XGROUP CREATE "${CORTEX_STREAM}" "${CORTEX_GROUP}" "0" MKSTREAM >/dev/null 2>&1 || true
}

# cortex_publish — append an event to the cortex stream
# Usage: cortex_publish <event_type> <agent_name> <summary> [project]
# Returns the new message ID on stdout.
cortex_publish() {
    local event_type="$1"
    local agent_name="$2"
    local summary="$3"
    local project="${4:-${CORTEX_PROJECT}}"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    rcli XADD "${CORTEX_STREAM}" "*" \
        type    "${event_type}" \
        agent   "${agent_name}" \
        summary "${summary}" \
        project "${project}" \
        ts      "${ts}"
}

# cortex_catchup — read all undelivered messages for this agent from the stream
# Usage: cortex_catchup <agent_name>
# Prints raw XREADGROUP output.
cortex_catchup() {
    local agent_name="$1"
    rcli XREADGROUP GROUP "${CORTEX_GROUP}" "${agent_name}" \
        COUNT 100 STREAMS "${CORTEX_STREAM}" ">"
}

# cortex_ack — acknowledge a processed message so it leaves the PEL
# Usage: cortex_ack <msg_id>
cortex_ack() {
    local msg_id="$1"
    rcli XACK "${CORTEX_STREAM}" "${CORTEX_GROUP}" "${msg_id}" >/dev/null
}

# ---------------------------------------------------------------------------
# Utility helpers (preserved from _lib.sh)
# ---------------------------------------------------------------------------

# status — print a coloured status line
# Usage: status green "All systems nominal"
status() {
    local color="$1"
    local msg="$2"
    case "${color}" in
        green)  printf '\033[32m%s\033[0m\n' "${msg}" ;;
        red)    printf '\033[31m%s\033[0m\n' "${msg}" ;;
        yellow) printf '\033[33m%s\033[0m\n' "${msg}" ;;
        *)      printf '%s\n' "${msg}" ;;
    esac
}

# read_file — return file contents, or empty string if file is missing
# Usage: content=$(read_file "/path/to/file")
read_file() {
    local path="$1"
    if [ -f "${path}" ]; then
        cat "${path}"
    else
        echo ""
    fi
}
