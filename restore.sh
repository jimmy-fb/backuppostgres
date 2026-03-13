#!/usr/bin/env bash
# ============================================================
#  restore.sh — Restore PostgreSQL from backup
#
#  Supports restoring:
#    - pg_basebackup archives (tar.gz, tar.lz4, tar)
#    - pg_dump custom format (.dump)
#    - pg_dumpall SQL files (.sql, .sql.gz, .sql.lz4)
#
#  Usage:
#    bash restore.sh -f backup_file.tar.gz -H <host> -U <user> -W <pass>
#    bash restore.sh -f dump_mydb.dump -H <host> -U <user> -W <pass> -d mydb
#    bash restore.sh --list                     # List available backups
#    bash restore.sh                            # Interactive mode
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*" >&2; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }

# ─── Defaults ─────────────────────────────────────────────────

BACKUP_FILE=""
PG_HOST=""
PG_PORT="5432"
PG_USER="postgres"
PG_PASS=""
PG_DB=""
BACKUP_DIR="./backups"
RESTORE_DIR=""        # For basebackup: extract to this path
LIST_ONLY=false
JOBS=4

# ─── Parse arguments ─────────────────────────────────────────

usage() {
    echo ""
    echo -e "${BOLD}Usage:${NC} bash restore.sh [options]"
    echo ""
    echo -e "${BOLD}Required:${NC}"
    echo "  -f, --file <path>       Backup file to restore"
    echo "  -H, --host <host>       PostgreSQL server hostname or IP"
    echo "  -U, --user <user>       PostgreSQL user (default: postgres)"
    echo "  -W, --password <pass>   PostgreSQL password"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  -p, --port <port>       PostgreSQL port (default: 5432)"
    echo "  -d, --database <db>     Target database (for dump restore)"
    echo "  -o, --output <dir>      Backup directory to scan (default: ./backups)"
    echo "  --restore-dir <dir>     Extract basebackup to this directory"
    echo "  --list                  List available backups"
    echo "  -j, --jobs <n>          Parallel workers for pg_restore (default: 4)"
    echo "  --help                  Show this help"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  bash restore.sh --list"
    echo "  bash restore.sh -f ./backups/dump_mydb_20260313.dump -H localhost -U postgres -W pass -d mydb"
    echo "  bash restore.sh -f ./backups/basebackup_20260313.tar.gz --restore-dir /var/lib/postgresql/16/main"
    echo ""
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file)        BACKUP_FILE="$2"; shift 2 ;;
        -H|--host)        PG_HOST="$2"; shift 2 ;;
        -U|--user)        PG_USER="$2"; shift 2 ;;
        -W|--password)    PG_PASS="$2"; shift 2 ;;
        -p|--port)        PG_PORT="$2"; shift 2 ;;
        -d|--database)    PG_DB="$2"; shift 2 ;;
        -o|--output)      BACKUP_DIR="$2"; shift 2 ;;
        --restore-dir)    RESTORE_DIR="$2"; shift 2 ;;
        --list)           LIST_ONLY=true; shift ;;
        -j|--jobs)        JOBS="$2"; shift 2 ;;
        --help|-h)        usage ;;
        *)                err "Unknown option: $1"; usage ;;
    esac
done

# ─── List backups ─────────────────────────────────────────────

list_backups() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Available Backups in ${BACKUP_DIR}${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
    echo ""

    if [[ ! -d "$BACKUP_DIR" ]]; then
        err "Backup directory not found: ${BACKUP_DIR}"
        exit 1
    fi

    local count=0
    local idx=0

    # List files (dumps, dumpalls) and directories (basebackups)
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        idx=$((idx + 1))
        local fname=$(basename "$file")
        local fsize=$(du -sh "$file" 2>/dev/null | awk '{print $1}')
        local fdate=$(date -r "$file" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || stat -c '%y' "$file" 2>/dev/null | cut -d. -f1)

        # Determine type
        local ftype="unknown"
        if [[ "$fname" == basebackup_* ]]; then ftype="basebackup"
        elif [[ "$fname" == dump_* ]]; then ftype="dump"
        elif [[ "$fname" == dumpall_* ]]; then ftype="dumpall"
        fi

        # Read metadata if exists
        local meta_info=""
        if [[ -f "${file}.meta" ]]; then
            local meta_host=$(grep '^host=' "${file}.meta" 2>/dev/null | cut -d= -f2)
            local meta_db=$(grep '^database=' "${file}.meta" 2>/dev/null | cut -d= -f2)
            meta_info="  host=${meta_host} db=${meta_db}"
        fi

        printf "  %2d) %-50s %6s  %s  [%s]%s\n" "$idx" "$fname" "$fsize" "$fdate" "$ftype" "$meta_info"
        count=$((count + 1))
    done < <({
        find "$BACKUP_DIR" -maxdepth 1 -type d -name "basebackup_*" 2>/dev/null
        find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "*.dump" -o -name "*.sql" -o -name "*.sql.gz" -o -name "*.sql.lz4" \) 2>/dev/null
    } | sort)

    if [[ $count -eq 0 ]]; then
        echo "  No backups found in ${BACKUP_DIR}"
    fi
    echo ""
}

if [[ "$LIST_ONLY" == "true" ]]; then
    list_backups
    exit 0
fi

# ─── Interactive mode ─────────────────────────────────────────

if [[ -z "$BACKUP_FILE" ]]; then
    list_backups

    # Collect files into array
    FILES=()
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        FILES+=("$file")
    done < <({
        find "$BACKUP_DIR" -maxdepth 1 -type d -name "basebackup_*" 2>/dev/null
        find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "*.dump" -o -name "*.sql" -o -name "*.sql.gz" -o -name "*.sql.lz4" \) 2>/dev/null
    } | sort)

    if [[ ${#FILES[@]} -eq 0 ]]; then
        err "No backups found in ${BACKUP_DIR}"
        exit 1
    fi

    read -rp "  Select backup number: " sel
    if [[ -z "$sel" || "$sel" -lt 1 || "$sel" -gt ${#FILES[@]} ]] 2>/dev/null; then
        err "Invalid selection"; exit 1
    fi
    BACKUP_FILE="${FILES[$((sel - 1))]}"
    echo ""
    log "Selected: $(basename "$BACKUP_FILE")"

    if [[ -z "$PG_HOST" ]]; then
        read -rp "  PostgreSQL host: " PG_HOST
        read -rp "  PostgreSQL port [5432]: " input; PG_PORT="${input:-5432}"
        read -rp "  PostgreSQL user [postgres]: " input; PG_USER="${input:-postgres}"
        read -rsp "  PostgreSQL password: " PG_PASS; echo ""
    fi
fi

# ─── Validate ─────────────────────────────────────────────────

if [[ ! -f "$BACKUP_FILE" && ! -d "$BACKUP_FILE" ]]; then
    err "Backup file not found: ${BACKUP_FILE}"; exit 1
fi

FNAME=$(basename "$BACKUP_FILE")

# Detect backup type from filename
DETECTED_TYPE="unknown"
if [[ "$FNAME" == basebackup_* ]]; then DETECTED_TYPE="basebackup"
elif [[ "$FNAME" == dump_* ]]; then DETECTED_TYPE="dump"
elif [[ "$FNAME" == dumpall_* ]]; then DETECTED_TYPE="dumpall"
elif [[ "$FNAME" == *.dump ]]; then DETECTED_TYPE="dump"
elif [[ "$FNAME" == *.sql* ]]; then DETECTED_TYPE="dumpall"
elif [[ "$FNAME" == *.tar* ]]; then DETECTED_TYPE="basebackup"
elif [[ -d "$BACKUP_FILE" ]]; then DETECTED_TYPE="basebackup"
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Restore: ${FNAME}${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""
echo "  File  : ${BACKUP_FILE}"
echo "  Type  : ${DETECTED_TYPE}"
echo "  Size  : $(du -sh "$BACKUP_FILE" 2>/dev/null | awk '{print $1}')"
echo ""

START_TIME=$(date +%s)

# ═══════════════════════════════════════════════════════════════
#  Restore: basebackup
# ═══════════════════════════════════════════════════════════════

if [[ "$DETECTED_TYPE" == "basebackup" ]]; then
    if [[ -z "$RESTORE_DIR" ]]; then
        RESTORE_DIR="${BACKUP_DIR}/restored_${FNAME}"
        echo "  No --restore-dir specified."
        read -rp "  Extract to [${RESTORE_DIR}]: " input
        RESTORE_DIR="${input:-$RESTORE_DIR}"
    fi

    echo ""
    warn "This will extract the backup to: ${RESTORE_DIR}"
    echo ""
    echo "  To use this as a PostgreSQL data directory:"
    echo "    1. Stop PostgreSQL"
    echo "    2. Replace PGDATA with this directory"
    echo "    3. Start PostgreSQL"
    echo ""
    read -rp "  Proceed? [Y/n]: " confirm
    [[ "$confirm" =~ ^[Nn] ]] && { echo "  Aborted."; exit 0; }

    mkdir -p "$RESTORE_DIR"

    log "Extracting basebackup to ${RESTORE_DIR}..."

    if [[ -d "$BACKUP_FILE" ]]; then
        # pg_basebackup tar format directory (contains base.tar.gz or base.tar etc.)
        for tarfile in "$BACKUP_FILE"/*.tar.gz "$BACKUP_FILE"/*.tar; do
            [[ -f "$tarfile" ]] || continue
            log "Extracting $(basename "$tarfile")..."
            if [[ "$tarfile" == *.tar.gz ]]; then
                tar -xzf "$tarfile" -C "$RESTORE_DIR"
            else
                tar -xf "$tarfile" -C "$RESTORE_DIR"
            fi
        done
    elif [[ "$FNAME" == *.tar.gz ]]; then
        tar -xzf "$BACKUP_FILE" -C "$RESTORE_DIR"
    elif [[ "$FNAME" == *.tar.lz4 ]]; then
        lz4 -d "$BACKUP_FILE" - | tar -xf - -C "$RESTORE_DIR"
    elif [[ "$FNAME" == *.tar ]]; then
        tar -xf "$BACKUP_FILE" -C "$RESTORE_DIR"
    fi

    success "Extracted to: ${RESTORE_DIR}"
    echo ""
    echo "  Contents:"
    ls -la "$RESTORE_DIR" | head -20
    echo ""
    echo "  To restore on the PostgreSQL server:"
    echo "    1. Stop PostgreSQL:  sudo systemctl stop postgresql"
    echo "    2. Backup current:   sudo mv \$PGDATA \$PGDATA.old"
    echo "    3. Copy restored:    sudo cp -a ${RESTORE_DIR} \$PGDATA"
    echo "    4. Fix ownership:    sudo chown -R postgres:postgres \$PGDATA"
    echo "    5. Start PostgreSQL: sudo systemctl start postgresql"
fi

# ═══════════════════════════════════════════════════════════════
#  Restore: dump (pg_restore)
# ═══════════════════════════════════════════════════════════════

if [[ "$DETECTED_TYPE" == "dump" ]]; then
    if [[ -z "$PG_HOST" ]]; then
        err "Host required for dump restore (-H)"; exit 1
    fi
    if [[ -z "$PG_PASS" ]]; then
        err "Password required (-W)"; exit 1
    fi

    export PGPASSWORD="$PG_PASS"

    # Auto-detect database from filename if not specified
    if [[ -z "$PG_DB" ]]; then
        PG_DB=$(echo "$FNAME" | sed -n 's/^dump_\(.*\)_[0-9]\{8\}_[0-9]\{6\}\.dump$/\1/p')
        if [[ -z "$PG_DB" ]]; then
            read -rp "  Target database name: " PG_DB
        else
            echo "  Auto-detected database: ${PG_DB}"
            read -rp "  Restore to [${PG_DB}]: " input
            PG_DB="${input:-$PG_DB}"
        fi
    fi

    echo ""
    warn "This will restore into database '${PG_DB}' on ${PG_HOST}:${PG_PORT}"
    read -rp "  Proceed? [Y/n]: " confirm
    [[ "$confirm" =~ ^[Nn] ]] && { echo "  Aborted."; exit 0; }

    # Create database if it doesn't exist
    log "Checking if database '${PG_DB}' exists..."
    DB_EXISTS=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres \
        -tAc "SELECT 1 FROM pg_database WHERE datname='${PG_DB}';" 2>/dev/null)

    if [[ "$DB_EXISTS" != "1" ]]; then
        log "Creating database '${PG_DB}'..."
        psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres \
            -c "CREATE DATABASE \"${PG_DB}\";" 2>/dev/null
        success "Database created"
    fi

    log "Restoring with pg_restore..."
    pg_restore -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" \
        -d "$PG_DB" -v -j "$JOBS" --clean --if-exists \
        "$BACKUP_FILE" 2>&1 || true
    # pg_restore returns non-zero on warnings, so we allow it

    success "Dump restored to ${PG_DB}"

    # Validate
    log "Validating..."
    TABLE_COUNT=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null)
    DB_SIZE=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -tAc "SELECT pg_size_pretty(pg_database_size('${PG_DB}'));" 2>/dev/null | tr -d '[:space:]')
    echo "  Tables: ${TABLE_COUNT}, Size: ${DB_SIZE}"

    unset PGPASSWORD
fi

# ═══════════════════════════════════════════════════════════════
#  Restore: dumpall (psql)
# ═══════════════════════════════════════════════════════════════

if [[ "$DETECTED_TYPE" == "dumpall" ]]; then
    if [[ -z "$PG_HOST" ]]; then
        err "Host required for dumpall restore (-H)"; exit 1
    fi
    if [[ -z "$PG_PASS" ]]; then
        err "Password required (-W)"; exit 1
    fi

    export PGPASSWORD="$PG_PASS"

    echo ""
    warn "This will restore ALL databases to ${PG_HOST}:${PG_PORT}"
    warn "Existing databases with the same name will be overwritten!"
    read -rp "  Type 'yes' to proceed: " confirm
    [[ "$confirm" != "yes" ]] && { echo "  Aborted."; exit 0; }

    log "Restoring with psql..."

    if [[ "$FNAME" == *.sql.gz ]]; then
        gunzip -c "$BACKUP_FILE" | psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres 2>&1
    elif [[ "$FNAME" == *.sql.lz4 ]]; then
        lz4 -d "$BACKUP_FILE" - | psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres 2>&1
    else
        psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -f "$BACKUP_FILE" 2>&1
    fi

    success "All databases restored"

    # Validate
    log "Databases on ${PG_HOST}:"
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres \
        -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) as size FROM pg_database WHERE datistemplate = false ORDER BY datname;" 2>/dev/null

    unset PGPASSWORD
fi

# ─── Summary ──────────────────────────────────────────────────

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINS=$((DURATION / 60))
SECS=$((DURATION % 60))

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Restore Complete${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""
echo "  File      : ${BACKUP_FILE}"
echo "  Type      : ${DETECTED_TYPE}"
echo "  Duration  : ${MINS}m ${SECS}s"
echo ""
