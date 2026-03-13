#!/usr/bin/env bash
# ============================================================
#  backup.sh — Take pgBackRest backups from the dedicated backup host
#
#  pgBackRest runs LOCALLY on this backup host.
#  It SSHes to the PG server automatically to stream data back here.
#  Backups are stored LOCALLY on this machine.
#
#  Usage:
#    bash backup.sh full          # Full backup
#    bash backup.sh diff          # Differential (changes since last full)
#    bash backup.sh incr          # Incremental (changes since last backup)
#    bash backup.sh info          # View backup info
#    bash backup.sh verify        # Verify backup integrity
#    bash backup.sh storage       # Show backup disk usage
#
#  Requires: setup.sh has been run first (creates .pgbackup.conf)
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
    echo "  Run setup.sh first to configure the backup host."
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# ─── Parse arguments ─────────────────────────────────────────

BACKUP_TYPE=""

usage() {
    echo ""
    echo -e "${BOLD}Usage:${NC} bash backup.sh <command> [options]"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo "  full         Take a full backup"
    echo "  diff         Take a differential backup (changes since last full)"
    echo "  incr         Take an incremental backup (changes since last backup)"
    echo "  info         Show backup information"
    echo "  verify       Verify backup integrity"
    echo "  storage      Show backup disk usage on this host"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  --stanza <name>      Override stanza name (default: from config)"
    echo "  --process-max <n>    Override parallel workers (default: from config)"
    echo "  --dry-run            Show what would be done without executing"
    echo "  --help               Show this help"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  bash backup.sh full"
    echo "  bash backup.sh diff --process-max 8"
    echo "  bash backup.sh info"
    echo ""
    exit 0
}

DRY_RUN=false

if [[ $# -lt 1 ]]; then
    usage
fi

case "${1}" in
    full|diff|incr)
        BACKUP_TYPE="$1"
        shift
        ;;
    info|verify|storage)
        BACKUP_TYPE="$1"
        shift
        ;;
    --help|-h)
        usage
        ;;
    *)
        err "Unknown command: $1"
        usage
        ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stanza)
            STANZA="$2"; shift 2
            ;;
        --process-max)
            PROCESS_MAX="$2"; shift 2
            ;;
        --dry-run)
            DRY_RUN=true; shift
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

# ─── Info / Verify / Storage ─────────────────────────────────

if [[ "$BACKUP_TYPE" == "info" ]]; then
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Backup Information — stored at ${BACKUP_DIR}${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""
    pgbackrest --stanza="${STANZA}" info
    echo ""
    exit 0
fi

if [[ "$BACKUP_TYPE" == "verify" ]]; then
    echo ""
    log "Verifying backups at ${BACKUP_DIR}..."
    pgbackrest --stanza="${STANZA}" verify
    success "Backup verification complete"
    echo ""
    exit 0
fi

if [[ "$BACKUP_TYPE" == "storage" ]]; then
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Backup Storage — ${BACKUP_DIR}${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BOLD}  Total size:${NC}"
    du -sh "${BACKUP_DIR}" 2>/dev/null || echo "  (unable to read)"
    echo ""
    echo -e "${BOLD}  Breakdown:${NC}"
    du -sh "${BACKUP_DIR}"/* 2>/dev/null || echo "  (empty)"
    echo ""
    echo -e "${BOLD}  Disk free:${NC}"
    df -h "${BACKUP_DIR}" 2>/dev/null
    echo ""
    exit 0
fi

# ─── Take backup ─────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  pgBackRest ${BACKUP_TYPE^^} Backup${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  PG Server : ${PG_HOST}"
echo "  Stanza    : ${STANZA}"
echo "  Type      : ${BACKUP_TYPE}"
echo "  Workers   : ${PROCESS_MAX}"
echo "  Compress  : ${COMPRESS_TYPE}"
echo "  Stored at : ${BACKUP_DIR} (this machine)"
echo ""

PBR_CMD="pgbackrest --stanza='${STANZA}' --type='${BACKUP_TYPE}' --process-max=${PROCESS_MAX} backup"

if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY RUN] Would execute locally:"
    echo "    ${PBR_CMD}"
    echo ""
    exit 0
fi

log "Starting ${BACKUP_TYPE} backup (streaming from ${PG_HOST})..."
START_TIME=$(date +%s)

eval "${PBR_CMD}"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINS=$((DURATION / 60))
SECS=$((DURATION % 60))

success "${BACKUP_TYPE^^} backup completed in ${MINS}m ${SECS}s"

# ─── Show result ──────────────────────────────────────────────

echo ""
log "Current backup status:"
echo ""
pgbackrest --stanza="${STANZA}" info

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Backup Complete — stored at ${BACKUP_DIR}${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
