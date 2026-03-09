#!/usr/bin/env bash
# ============================================================
#  restore.sh — Restore PostgreSQL from pgBackRest on a remote server
#
#  Usage:
#    bash restore.sh                              # Interactive — list and choose
#    bash restore.sh --latest                     # Restore latest backup
#    bash restore.sh --set 20260309-075435F       # Restore specific backup set
#    bash restore.sh --pitr '2026-03-09 08:00:00' # Point-in-time recovery
#    bash restore.sh --info                       # List available backups
#    bash restore.sh --verify                     # Verify backup integrity
#
#  Requires: setup.sh has been run first (creates .pgbackup.conf)
#
#  WARNING: Restore stops PostgreSQL, replaces data, and restarts.
#           Use with caution on production servers.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/.pgbackup.conf"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*" >&2; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }

# ─── Load config ─────────────────────────────────────────────

if [[ ! -f "$CONFIG_FILE" ]]; then
    err "Config file not found: ${CONFIG_FILE}"
    echo "  Run setup.sh first to configure the remote server."
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

SSH_CMD="ssh -p ${SSH_PORT} -o StrictHostKeyChecking=accept-new ${SSH_USER}@${SSH_HOST}"

# ─── Parse arguments ─────────────────────────────────────────

MODE=""         # latest, set, pitr, info, verify, interactive
SET_LABEL=""
PITR_TARGET=""
DELTA=true

usage() {
    echo ""
    echo -e "${BOLD}Usage:${NC} bash restore.sh [options]"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  --latest               Restore the latest backup"
    echo "  --set <label>          Restore a specific backup set"
    echo "  --pitr <timestamp>     Point-in-time recovery (e.g. '2026-03-09 08:00:00+00')"
    echo "  --info                 List available backups"
    echo "  --verify               Verify backup integrity"
    echo "  --no-delta             Full restore (don't use delta — slower but safer)"
    echo "  --stanza <name>        Override stanza name"
    echo "  --help                 Show this help"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  bash restore.sh --latest"
    echo "  bash restore.sh --set 20260309-075435F"
    echo "  bash restore.sh --pitr '2026-03-09 14:30:00+00'"
    echo "  bash restore.sh --info"
    echo ""
    echo -e "${YELLOW}WARNING:${NC} Restore will stop PostgreSQL, replace data, and restart."
    echo ""
    exit 0
}

if [[ $# -lt 1 ]]; then
    MODE="interactive"
else
    case "$1" in
        --latest)
            MODE="latest"; shift
            ;;
        --set)
            MODE="set"; SET_LABEL="$2"; shift 2
            ;;
        --pitr)
            MODE="pitr"; PITR_TARGET="$2"; shift 2
            ;;
        --info)
            MODE="info"; shift
            ;;
        --verify)
            MODE="verify"; shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            err "Unknown option: $1"
            usage
            ;;
    esac
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-delta)
            DELTA=false; shift
            ;;
        --stanza)
            STANZA="$2"; shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            err "Unknown option: $1"
            usage
            ;;
    esac
done

# ─── Test SSH ─────────────────────────────────────────────────

log "Connecting to ${SSH_USER}@${SSH_HOST}:${SSH_PORT}..."

if ! ${SSH_CMD} "echo 'ok'" &>/dev/null; then
    err "Cannot SSH to ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
    exit 1
fi

# ─── Info / Verify ────────────────────────────────────────────

if [[ "$MODE" == "info" ]]; then
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Available Backups — ${SSH_HOST}${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""
    ${SSH_CMD} "sudo -u postgres pgbackrest --stanza='${STANZA}' info"
    echo ""
    exit 0
fi

if [[ "$MODE" == "verify" ]]; then
    log "Verifying backups on ${SSH_HOST}..."
    ${SSH_CMD} "sudo -u postgres pgbackrest --stanza='${STANZA}' verify"
    success "Verification complete"
    exit 0
fi

# ─── Interactive mode ─────────────────────────────────────────

if [[ "$MODE" == "interactive" ]]; then
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  PostgreSQL Restore — ${SSH_HOST}${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BOLD}Available backups:${NC}"
    echo ""
    ${SSH_CMD} "sudo -u postgres pgbackrest --stanza='${STANZA}' info"
    echo ""
    echo -e "${BOLD}Restore options:${NC}"
    echo "  1) Restore latest backup"
    echo "  2) Restore specific backup set"
    echo "  3) Point-in-time recovery"
    echo "  4) Cancel"
    echo ""
    read -rp "  Select [1-4]: " choice

    case "${choice}" in
        1)
            MODE="latest"
            ;;
        2)
            read -rp "  Enter backup set label: " SET_LABEL
            if [[ -z "$SET_LABEL" ]]; then
                err "Backup set label is required"
                exit 1
            fi
            MODE="set"
            ;;
        3)
            read -rp "  Enter target time (e.g. '2026-03-09 14:30:00+00'): " PITR_TARGET
            if [[ -z "$PITR_TARGET" ]]; then
                err "PITR target time is required"
                exit 1
            fi
            MODE="pitr"
            ;;
        *)
            echo "  Cancelled."
            exit 0
            ;;
    esac
fi

# ─── Confirm ──────────────────────────────────────────────────

echo ""
echo -e "${YELLOW}${BOLD}  ⚠  WARNING: This will restore PostgreSQL on ${SSH_HOST}${NC}"
echo ""
echo "  What will happen:"
echo "    1. PostgreSQL will be STOPPED"
echo "    2. Data directory (${PG_DATA}) will be REPLACED"
echo "    3. PostgreSQL will be RESTARTED"
echo ""
case "$MODE" in
    latest)
        echo "  Restore: Latest backup"
        ;;
    set)
        echo "  Restore: Backup set ${SET_LABEL}"
        ;;
    pitr)
        echo "  Restore: Point-in-time recovery to ${PITR_TARGET}"
        ;;
esac
echo ""
read -rp "  Type 'yes' to proceed: " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "  Aborted."
    exit 0
fi

# ─── Stop PostgreSQL ──────────────────────────────────────────

echo ""
log "Stopping PostgreSQL on ${SSH_HOST}..."

${SSH_CMD} "
    if command -v systemctl &>/dev/null && systemctl list-units --type=service 2>/dev/null | grep -q postgresql; then
        SVC=\$(systemctl list-units --type=service 2>/dev/null | grep postgresql | awk '{print \$1}' | head -1)
        $([ "${SSH_USER}" != "root" ] && echo "sudo") systemctl stop \"\$SVC\"
    else
        sudo -u postgres pg_ctl -D '${PG_DATA}' stop -m fast 2>/dev/null || true
    fi
"

success "PostgreSQL stopped"

# ─── Run pgBackRest restore ──────────────────────────────────

log "Running pgBackRest restore..."

RESTORE_CMD="sudo -u postgres pgbackrest --stanza='${STANZA}'"

if [[ "$DELTA" == "true" ]]; then
    RESTORE_CMD+=" --delta"
fi

RESTORE_CMD+=" --process-max=${PROCESS_MAX}"

case "$MODE" in
    latest)
        RESTORE_CMD+=" restore"
        ;;
    set)
        RESTORE_CMD+=" --set='${SET_LABEL}' restore"
        ;;
    pitr)
        RESTORE_CMD+=" --type=time --target='${PITR_TARGET}' --target-action=promote restore"
        ;;
esac

log "Command: ${RESTORE_CMD}"
START_TIME=$(date +%s)

${SSH_CMD} "${RESTORE_CMD}"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINS=$((DURATION / 60))
SECS=$((DURATION % 60))

success "Restore completed in ${MINS}m ${SECS}s"

# ─── Start PostgreSQL ─────────────────────────────────────────

log "Starting PostgreSQL on ${SSH_HOST}..."

${SSH_CMD} "
    if command -v systemctl &>/dev/null && systemctl list-units --type=service --all 2>/dev/null | grep -q postgresql; then
        SVC=\$(systemctl list-units --type=service --all 2>/dev/null | grep postgresql | awk '{print \$1}' | head -1)
        $([ "${SSH_USER}" != "root" ] && echo "sudo") systemctl start \"\$SVC\"
    else
        sudo -u postgres pg_ctl -D '${PG_DATA}' start -l '${LOG_DIR}/pg_startup.log'
    fi
"

# Wait for PostgreSQL to be ready
log "Waiting for PostgreSQL to be ready..."
RETRIES=30
for i in $(seq 1 $RETRIES); do
    if ${SSH_CMD} "sudo -u postgres pg_isready -p ${PG_PORT}" &>/dev/null; then
        break
    fi
    if [[ $i -eq $RETRIES ]]; then
        err "PostgreSQL did not start within ${RETRIES} seconds"
        echo "  Check logs on ${SSH_HOST}: ${LOG_DIR}/pg_startup.log"
        exit 1
    fi
    sleep 1
done

success "PostgreSQL started and accepting connections"

# ─── Validate ─────────────────────────────────────────────────

log "Validating restore..."
echo ""

DB_LIST=$(${SSH_CMD} "sudo -u postgres psql -p ${PG_PORT} -tAc \"SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;\"" 2>/dev/null)

echo -e "${BOLD}  Databases:${NC}"
while IFS= read -r db; do
    [[ -z "$db" ]] && continue
    SIZE=$(${SSH_CMD} "sudo -u postgres psql -p ${PG_PORT} -tAc \"SELECT pg_size_pretty(pg_database_size('${db}'));\"" 2>/dev/null | tr -d '[:space:]')
    echo "    ${db}  (${SIZE})"
done <<< "$DB_LIST"

echo ""

# ─── Done ─────────────────────────────────────────────────────

echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Restore Complete${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  Server    : ${SSH_USER}@${SSH_HOST}"
echo "  Stanza    : ${STANZA}"
echo "  PGDATA    : ${PG_DATA}"
echo "  Duration  : ${MINS}m ${SECS}s"
echo ""
