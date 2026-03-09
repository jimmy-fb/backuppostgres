#!/usr/bin/env bash
# ============================================================
#  backup.sh — Take pgBackRest backups on a remote PostgreSQL server
#
#  Usage:
#    bash backup.sh full          # Full backup
#    bash backup.sh diff          # Differential (changes since last full)
#    bash backup.sh incr          # Incremental (changes since last backup)
#    bash backup.sh info          # View backup info
#    bash backup.sh verify        # Verify backup integrity
#    bash backup.sh storage       # Show backup disk usage
#
#  Options:
#    --backup-dir /custom/path    Override backup directory on remote server
#    --pull /local/path           Download backup repo to local machine after backup
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
    echo "  Run setup.sh first to configure the remote server."
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

SSH_CMD="ssh -p ${SSH_PORT} -o StrictHostKeyChecking=accept-new ${SSH_USER}@${SSH_HOST}"

# ─── Parse arguments ─────────────────────────────────────────

BACKUP_TYPE=""
PULL_DIR=""

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
    echo "  storage      Show backup disk usage on remote server"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  --backup-dir <dir>   Override backup directory on remote server"
    echo "  --pull <local-dir>   Download backup repo to local machine after backup"
    echo "  --stanza <name>      Override stanza name (default: from config)"
    echo "  --process-max <n>    Override parallel workers (default: from config)"
    echo "  --dry-run            Show what would be done without executing"
    echo "  --help               Show this help"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  bash backup.sh full"
    echo "  bash backup.sh full --backup-dir /mnt/nfs/pgbackups"
    echo "  bash backup.sh full --pull /local/backups"
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
        --backup-dir)
            BACKUP_DIR="$2"; shift 2
            ;;
        --pull)
            PULL_DIR="$2"; shift 2
            ;;
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

# ─── Test SSH ─────────────────────────────────────────────────

log "Connecting to ${SSH_USER}@${SSH_HOST}:${SSH_PORT}..."

if ! ${SSH_CMD} "echo 'ok'" &>/dev/null; then
    err "Cannot SSH to ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
    echo "  Check your SSH connection and try again."
    exit 1
fi

# ─── Info / Verify ────────────────────────────────────────────

if [[ "$BACKUP_TYPE" == "info" ]]; then
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Backup Information — ${SSH_HOST}${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""
    ${SSH_CMD} "sudo -u postgres pgbackrest --stanza='${STANZA}' info"
    echo ""
    exit 0
fi

if [[ "$BACKUP_TYPE" == "verify" ]]; then
    echo ""
    log "Verifying backups on ${SSH_HOST}..."
    ${SSH_CMD} "sudo -u postgres pgbackrest --stanza='${STANZA}' verify"
    success "Backup verification complete"
    echo ""
    exit 0
fi

if [[ "$BACKUP_TYPE" == "storage" ]]; then
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Backup Storage — ${SSH_HOST}${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BOLD}  Backup directory: ${BACKUP_DIR}${NC}"
    ${SSH_CMD} "sudo du -sh '${BACKUP_DIR}' 2>/dev/null || echo '  (unable to read)'"
    echo ""
    echo -e "${BOLD}  Breakdown:${NC}"
    ${SSH_CMD} "sudo du -sh '${BACKUP_DIR}'/* 2>/dev/null || echo '  (empty)'"
    echo ""
    echo -e "${BOLD}  Disk free:${NC}"
    ${SSH_CMD} "df -h '${BACKUP_DIR}' 2>/dev/null"
    echo ""
    exit 0
fi

# ─── Take backup ──────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  pgBackRest ${BACKUP_TYPE^^} Backup${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  Server    : ${SSH_USER}@${SSH_HOST}"
echo "  Stanza    : ${STANZA}"
echo "  Type      : ${BACKUP_TYPE}"
echo "  Workers   : ${PROCESS_MAX}"
echo "  Compress  : ${COMPRESS_TYPE}"
echo "  Backup dir: ${BACKUP_DIR}"
echo ""

PBR_CMD="sudo -u postgres pgbackrest --stanza='${STANZA}' --type='${BACKUP_TYPE}' --process-max=${PROCESS_MAX} backup"

if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY RUN] Would execute on ${SSH_HOST}:"
    echo "    ${PBR_CMD}"
    echo ""
    exit 0
fi

log "Starting ${BACKUP_TYPE} backup..."
START_TIME=$(date +%s)

${SSH_CMD} "${PBR_CMD}"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINS=$((DURATION / 60))
SECS=$((DURATION % 60))

success "${BACKUP_TYPE^^} backup completed in ${MINS}m ${SECS}s"

# ─── Show result ──────────────────────────────────────────────

echo ""
log "Current backup status:"
echo ""
${SSH_CMD} "sudo -u postgres pgbackrest --stanza='${STANZA}' info"

# ─── Pull backups to local machine ────────────────────────────

if [[ -n "$PULL_DIR" ]]; then
    echo ""
    log "Downloading backup repo to ${PULL_DIR}..."
    mkdir -p "$PULL_DIR"
    rsync -avz --progress \
        -e "ssh -p ${SSH_PORT}" \
        "${SSH_USER}@${SSH_HOST}:${BACKUP_DIR}/" \
        "${PULL_DIR}/"
    success "Backup repo downloaded to ${PULL_DIR}"
    echo ""
    echo "  Local copy: ${PULL_DIR}"
    du -sh "$PULL_DIR" 2>/dev/null || true
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Backup Complete${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
