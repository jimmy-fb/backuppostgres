#!/usr/bin/env bash
# ============================================================
#  restore.sh — Restore PostgreSQL from the dedicated backup host
#
#  pgBackRest runs LOCALLY on this backup host.
#  It SSHes to the PG server to restore data from backups stored here.
#
#  Usage:
#    bash restore.sh                              # Interactive
#    bash restore.sh --latest                     # Restore latest backup
#    bash restore.sh --set 20260309-075435F       # Restore specific set
#    bash restore.sh --pitr '2026-03-09 08:00:00' # Point-in-time recovery
#    bash restore.sh --info                       # List available backups
#    bash restore.sh --verify                     # Verify integrity
#
#  WARNING: Restore stops PostgreSQL, replaces data, and restarts.
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
    echo "  Run setup.sh first."
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

SSH_CMD="ssh -p ${SSH_PORT} -o StrictHostKeyChecking=accept-new ${SSH_USER}@${PG_HOST}"

# ─── Parse arguments ─────────────────────────────────────────

MODE=""
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
    echo "  --pitr <timestamp>     Point-in-time recovery"
    echo "  --info                 List available backups"
    echo "  --verify               Verify backup integrity"
    echo "  --no-delta             Full restore (don't use delta)"
    echo "  --stanza <name>        Override stanza name"
    echo "  --help                 Show this help"
    echo ""
    exit 0
}

if [[ $# -lt 1 ]]; then
    MODE="interactive"
else
    case "$1" in
        --latest)   MODE="latest"; shift ;;
        --set)      MODE="set"; SET_LABEL="$2"; shift 2 ;;
        --pitr)     MODE="pitr"; PITR_TARGET="$2"; shift 2 ;;
        --info)     MODE="info"; shift ;;
        --verify)   MODE="verify"; shift ;;
        --help|-h)  usage ;;
        *)          err "Unknown option: $1"; usage ;;
    esac
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-delta) DELTA=false; shift ;;
        --stanza)   STANZA="$2"; shift 2 ;;
        --help|-h)  usage ;;
        *)          err "Unknown option: $1"; usage ;;
    esac
done

# ─── Info / Verify ────────────────────────────────────────────

if [[ "$MODE" == "info" ]]; then
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Available Backups — ${BACKUP_DIR}${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""
    pgbackrest --stanza="${STANZA}" info
    echo ""
    exit 0
fi

if [[ "$MODE" == "verify" ]]; then
    log "Verifying backups..."
    pgbackrest --stanza="${STANZA}" verify
    success "Verification complete"
    exit 0
fi

# ─── Interactive mode ─────────────────────────────────────────

if [[ "$MODE" == "interactive" ]]; then
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  PostgreSQL Restore — from ${BACKUP_DIR}${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BOLD}Available backups:${NC}"
    echo ""
    pgbackrest --stanza="${STANZA}" info
    echo ""
    echo -e "${BOLD}Restore options:${NC}"
    echo "  1) Restore latest backup"
    echo "  2) Restore specific backup set"
    echo "  3) Point-in-time recovery"
    echo "  4) Cancel"
    echo ""
    read -rp "  Select [1-4]: " choice

    case "${choice}" in
        1) MODE="latest" ;;
        2)
            read -rp "  Enter backup set label: " SET_LABEL
            [[ -z "$SET_LABEL" ]] && { err "Label required"; exit 1; }
            MODE="set"
            ;;
        3)
            read -rp "  Enter target time (e.g. '2026-03-09 14:30:00+00'): " PITR_TARGET
            [[ -z "$PITR_TARGET" ]] && { err "Target time required"; exit 1; }
            MODE="pitr"
            ;;
        *) echo "  Cancelled."; exit 0 ;;
    esac
fi

# ─── Confirm ──────────────────────────────────────────────────

echo ""
echo -e "${YELLOW}${BOLD}  WARNING: This will restore PostgreSQL on ${PG_HOST}${NC}"
echo ""
echo "  What will happen:"
echo "    1. PostgreSQL on ${PG_HOST} will be STOPPED (via SSH)"
echo "    2. Data directory (${PG_DATA}) will be REPLACED"
echo "    3. Restore streams from THIS machine → PG server"
echo "    4. PostgreSQL will be RESTARTED"
echo ""
case "$MODE" in
    latest) echo "  Restore: Latest backup" ;;
    set)    echo "  Restore: Backup set ${SET_LABEL}" ;;
    pitr)   echo "  Restore: PITR to ${PITR_TARGET}" ;;
esac
echo ""
read -rp "  Type 'yes' to proceed: " confirm
[[ "$confirm" != "yes" ]] && { echo "  Aborted."; exit 0; }

# ─── Stop PostgreSQL on PG server ─────────────────────────────

echo ""
log "Stopping PostgreSQL on ${PG_HOST}..."

${SSH_CMD} "
    if command -v systemctl &>/dev/null && systemctl list-units --type=service 2>/dev/null | grep -q postgresql; then
        SVC=\$(systemctl list-units --type=service 2>/dev/null | grep postgresql | awk '{print \$1}' | head -1)
        $([ "${SSH_USER}" != "root" ] && echo "sudo") systemctl stop \"\$SVC\"
    else
        sudo -u postgres pg_ctl -D '${PG_DATA}' stop -m fast 2>/dev/null || true
    fi
"

success "PostgreSQL stopped on ${PG_HOST}"

# ─── Run pgBackRest restore (from backup host) ───────────────

log "Restoring from backup host to ${PG_HOST}..."

RESTORE_CMD="pgbackrest --stanza='${STANZA}'"

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

eval "${RESTORE_CMD}"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINS=$((DURATION / 60))
SECS=$((DURATION % 60))

success "Restore completed in ${MINS}m ${SECS}s"

# ─── Start PostgreSQL on PG server ────────────────────────────

log "Starting PostgreSQL on ${PG_HOST}..."

${SSH_CMD} "
    if command -v systemctl &>/dev/null && systemctl list-units --type=service --all 2>/dev/null | grep -q postgresql; then
        SVC=\$(systemctl list-units --type=service --all 2>/dev/null | grep postgresql | awk '{print \$1}' | head -1)
        $([ "${SSH_USER}" != "root" ] && echo "sudo") systemctl start \"\$SVC\"
    else
        sudo -u postgres pg_ctl -D '${PG_DATA}' start -l /var/log/pgbackrest/pg_startup.log
    fi
"

log "Waiting for PostgreSQL to be ready..."
RETRIES=30
for i in $(seq 1 $RETRIES); do
    if ${SSH_CMD} "sudo -u postgres pg_isready -p ${PG_PORT}" &>/dev/null; then
        break
    fi
    if [[ $i -eq $RETRIES ]]; then
        err "PostgreSQL did not start within ${RETRIES} seconds"
        exit 1
    fi
    sleep 1
done

success "PostgreSQL started on ${PG_HOST}"

# ─── Validate ─────────────────────────────────────────────────

log "Validating restore..."
echo ""

DB_LIST=$(${SSH_CMD} "sudo -u postgres psql -p ${PG_PORT} -tAc \"SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;\"" 2>/dev/null)

echo -e "${BOLD}  Databases on ${PG_HOST}:${NC}"
while IFS= read -r db; do
    [[ -z "$db" ]] && continue
    SIZE=$(${SSH_CMD} "sudo -u postgres psql -p ${PG_PORT} -tAc \"SELECT pg_size_pretty(pg_database_size('${db}'));\"" 2>/dev/null | tr -d '[:space:]')
    echo "    ${db}  (${SIZE})"
done <<< "$DB_LIST"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Restore Complete${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  PG Server : ${PG_HOST}"
echo "  Stanza    : ${STANZA}"
echo "  PGDATA    : ${PG_DATA}"
echo "  Duration  : ${MINS}m ${SECS}s"
echo "  Backup src: ${BACKUP_DIR} (this machine)"
echo ""
