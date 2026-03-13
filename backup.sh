#!/usr/bin/env bash
# ============================================================
#  backup.sh — PostgreSQL backup using pg_basebackup + pg_dump
#
#  Connects to PostgreSQL over its native protocol (port 5432).
#  No SSH. No extra packages on the server. Just PostgreSQL tools.
#
#  Usage:
#    bash backup.sh -H <host> -U <user> -W <password>
#    bash backup.sh -H <host> -U <user> -W <password> -t dump -d mydb
#    bash backup.sh    (interactive mode)
#
#  Backup types:
#    basebackup  — Full physical backup (entire cluster, supports PITR)
#    dump        — Logical SQL dump (single database, portable)
#    dumpall     — Logical SQL dump (all databases)
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── Defaults ─────────────────────────────────────────────────

PG_HOST=""
PG_PORT="5432"
PG_USER="postgres"
PG_PASS=""
PG_DB=""
BACKUP_TYPE="basebackup"
BACKUP_DIR="./backups"
COMPRESS="gzip"       # gzip, lz4, none
JOBS=4
MAX_RATE=""           # e.g. "100M" to limit bandwidth

# ─── Parse arguments ─────────────────────────────────────────

usage() {
    echo ""
    echo -e "${BOLD}Usage:${NC} bash backup.sh [options]"
    echo ""
    echo -e "${BOLD}Required:${NC}"
    echo "  -H, --host <host>       PostgreSQL server hostname or IP"
    echo "  -U, --user <user>       PostgreSQL user (default: postgres)"
    echo "  -W, --password <pass>   PostgreSQL password"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  -p, --port <port>       PostgreSQL port (default: 5432)"
    echo "  -t, --type <type>       Backup type: basebackup, dump, dumpall (default: basebackup)"
    echo "  -d, --database <db>     Database name (required for dump type)"
    echo "  -o, --output <dir>      Backup output directory (default: ./backups)"
    echo "  -c, --compress <type>   Compression: gzip, lz4, none (default: gzip)"
    echo "  -j, --jobs <n>          Parallel workers (default: 4)"
    echo "  --max-rate <rate>       Max transfer rate, e.g. 100M (default: unlimited)"
    echo "  --help                  Show this help"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  bash backup.sh -H 10.0.0.5 -U postgres -W mypass"
    echo "  bash backup.sh -H db.example.com -U admin -W secret -t dump -d myapp"
    echo "  bash backup.sh -H 10.0.0.5 -U postgres -W pass -c lz4 -j 8"
    echo ""
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -H|--host)      PG_HOST="$2"; shift 2 ;;
        -U|--user)      PG_USER="$2"; shift 2 ;;
        -W|--password)  PG_PASS="$2"; shift 2 ;;
        -p|--port)      PG_PORT="$2"; shift 2 ;;
        -t|--type)      BACKUP_TYPE="$2"; shift 2 ;;
        -d|--database)  PG_DB="$2"; shift 2 ;;
        -o|--output)    BACKUP_DIR="$2"; shift 2 ;;
        -c|--compress)  COMPRESS="$2"; shift 2 ;;
        -j|--jobs)      JOBS="$2"; shift 2 ;;
        --max-rate)     MAX_RATE="$2"; shift 2 ;;
        --help|-h)      usage ;;
        *)              err "Unknown option: $1"; usage ;;
    esac
done

# ─── Interactive mode ─────────────────────────────────────────

if [[ -z "$PG_HOST" ]]; then
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  PostgreSQL Backup${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
    echo ""
    read -rp "  PostgreSQL host: " PG_HOST
    read -rp "  PostgreSQL port [5432]: " input; PG_PORT="${input:-5432}"
    read -rp "  PostgreSQL user [postgres]: " input; PG_USER="${input:-postgres}"
    read -rsp "  PostgreSQL password: " PG_PASS; echo ""
    echo ""
    echo "  Backup type:"
    echo "    1) basebackup — Full physical (entire cluster, PITR capable)"
    echo "    2) dump       — SQL dump (single database)"
    echo "    3) dumpall    — SQL dump (all databases)"
    read -rp "  Select [1]: " bt_choice
    case "${bt_choice:-1}" in
        1) BACKUP_TYPE="basebackup" ;;
        2) BACKUP_TYPE="dump"; read -rp "  Database name: " PG_DB ;;
        3) BACKUP_TYPE="dumpall" ;;
    esac
    read -rp "  Output directory [./backups]: " input; BACKUP_DIR="${input:-./backups}"
    echo ""
fi

# ─── Validate ─────────────────────────────────────────────────

if [[ -z "$PG_HOST" ]]; then err "Host is required (-H)"; exit 1; fi
if [[ -z "$PG_PASS" ]]; then err "Password is required (-W)"; exit 1; fi
if [[ "$BACKUP_TYPE" == "dump" && -z "$PG_DB" ]]; then
    err "Database name required for dump type (-d)"; exit 1
fi

export PGPASSWORD="$PG_PASS"

# ─── Test connection ──────────────────────────────────────────

log "Connecting to ${PG_HOST}:${PG_PORT} as ${PG_USER}..."

PG_VERSION=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -tAc "SELECT version();" 2>/dev/null) || {
    err "Cannot connect to PostgreSQL at ${PG_HOST}:${PG_PORT}"
    echo "  Check: host, port, user, password, and pg_hba.conf on the server"
    exit 1
}

success "Connected — ${PG_VERSION}"

# ─── Prepare output ──────────────────────────────────────────

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
mkdir -p "$BACKUP_DIR"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Starting ${BACKUP_TYPE^^} Backup${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""
echo "  Server    : ${PG_HOST}:${PG_PORT}"
echo "  User      : ${PG_USER}"
echo "  Type      : ${BACKUP_TYPE}"
echo "  Compress  : ${COMPRESS}"
echo "  Output    : ${BACKUP_DIR}"
echo ""

START_TIME=$(date +%s)

# ─── basebackup ──────────────────────────────────────────────

if [[ "$BACKUP_TYPE" == "basebackup" ]]; then
    BACKUP_FILE="${BACKUP_DIR}/basebackup_${TIMESTAMP}.tar"

    BACKUP_FILE="${BACKUP_DIR}/basebackup_${TIMESTAMP}"

    ARGS=(-h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -Ft -Xf -P)

    if [[ -n "$MAX_RATE" ]]; then
        ARGS+=(--max-rate="$MAX_RATE")
    fi

    case "$COMPRESS" in
        gzip)
            ARGS+=(-z)
            ;;
        lz4)
            ARGS+=(--compress=lz4)
            ;;
        none)
            ;;
        *)
            ARGS+=(-z)
            ;;
    esac

    ARGS+=(-D "$BACKUP_FILE")

    log "Running pg_basebackup..."
    pg_basebackup "${ARGS[@]}"

    BACKUP_SIZE=$(du -sh "$BACKUP_FILE" 2>/dev/null | awk '{print $1}')
    success "Backup saved: ${BACKUP_FILE}/ (${BACKUP_SIZE})"
fi

# ─── dump ─────────────────────────────────────────────────────

if [[ "$BACKUP_TYPE" == "dump" ]]; then
    BACKUP_FILE="${BACKUP_DIR}/dump_${PG_DB}_${TIMESTAMP}.dump"

    log "Running pg_dump on '${PG_DB}' (custom format, compressed)..."
    pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" \
        -v --format=custom -f "$BACKUP_FILE" "$PG_DB" 2>&1

    BACKUP_SIZE=$(du -sh "$BACKUP_FILE" 2>/dev/null | awk '{print $1}')
    success "Backup saved: ${BACKUP_FILE} (${BACKUP_SIZE})"
fi

# ─── dumpall ──────────────────────────────────────────────────

if [[ "$BACKUP_TYPE" == "dumpall" ]]; then
    BACKUP_FILE="${BACKUP_DIR}/dumpall_${TIMESTAMP}.sql"

    case "$COMPRESS" in
        gzip)
            BACKUP_FILE+=".gz"
            log "Running pg_dumpall (gzip)..."
            pg_dumpall -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" 2>/dev/null | gzip > "$BACKUP_FILE"
            ;;
        lz4)
            BACKUP_FILE+=".lz4"
            log "Running pg_dumpall (lz4)..."
            pg_dumpall -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" 2>/dev/null | lz4 > "$BACKUP_FILE"
            ;;
        none)
            log "Running pg_dumpall (plain SQL)..."
            pg_dumpall -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" \
                -f "$BACKUP_FILE" 2>/dev/null
            ;;
        *)
            BACKUP_FILE+=".gz"
            log "Running pg_dumpall (gzip)..."
            pg_dumpall -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" 2>/dev/null | gzip > "$BACKUP_FILE"
            ;;
    esac

    BACKUP_SIZE=$(du -sh "$BACKUP_FILE" 2>/dev/null | awk '{print $1}')
    success "Backup saved: ${BACKUP_FILE} (${BACKUP_SIZE})"
fi

# ─── Summary ──────────────────────────────────────────────────

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINS=$((DURATION / 60))
SECS=$((DURATION % 60))

# Save metadata
META_FILE="${BACKUP_FILE}.meta"
cat > "$META_FILE" <<EOF
backup_type=${BACKUP_TYPE}
host=${PG_HOST}
port=${PG_PORT}
user=${PG_USER}
database=${PG_DB:-all}
timestamp=${TIMESTAMP}
file=${BACKUP_FILE}
size=${BACKUP_SIZE}
compress=${COMPRESS}
duration_seconds=${DURATION}
pg_version=${PG_VERSION}
EOF

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Backup Complete${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""
echo "  File      : ${BACKUP_FILE}"
echo "  Size      : ${BACKUP_SIZE}"
echo "  Duration  : ${MINS}m ${SECS}s"
echo "  Metadata  : ${META_FILE}"
echo ""

unset PGPASSWORD
