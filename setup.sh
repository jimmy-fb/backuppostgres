#!/usr/bin/env bash
# ============================================================
#  setup.sh — One-time setup for PostgreSQL remote backup
#
#  What this does:
#    1. SSHes to your remote PostgreSQL server
#    2. Installs pgBackRest on the remote server
#    3. Configures pgBackRest + WAL archiving
#    4. Creates and verifies the backup stanza
#    5. Saves a local config file for backup/restore scripts
#
#  Run this ONCE from your workstation / backup server.
#  After setup, use backup.sh and restore.sh.
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

# ─── Collect details ─────────────────────────────────────────

prompt() {
    local varname="$1" msg="$2" default="${3:-}"
    local val
    if [[ -n "$default" ]]; then
        read -rp "  ${msg} [${default}]: " val
        val="${val:-$default}"
    else
        read -rp "  ${msg}: " val
    fi
    if [[ -z "$val" ]]; then
        err "${msg} is required"; exit 1
    fi
    eval "$varname=\"\$val\""
}

prompt_secret() {
    local varname="$1" msg="$2"
    local val
    read -rsp "  ${msg}: " val; echo ""
    eval "$varname=\"\$val\""
}

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  PostgreSQL Remote Backup — Setup${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}Remote PostgreSQL Server:${NC}"
prompt  SSH_HOST        "SSH hostname or IP"
prompt  SSH_USER        "SSH user (must have sudo)"   "root"
prompt  SSH_PORT        "SSH port"                    "22"
echo ""
echo -e "${BOLD}PostgreSQL:${NC}"
prompt  PG_PORT         "PostgreSQL port"             "5432"
prompt  PG_USER         "PostgreSQL superuser"        "postgres"
prompt  PG_DATA         "PGDATA directory"            "/var/lib/postgresql/16/main"
echo ""
echo -e "${BOLD}Backup Settings:${NC}"
prompt  STANZA          "Stanza name"                 "main"
prompt  BACKUP_DIR      "Backup directory on remote"  "/var/lib/pgbackrest"
prompt  LOG_DIR         "Log directory on remote"     "/var/log/pgbackrest"
prompt  PROCESS_MAX     "Parallel workers"            "4"

echo ""
echo -e "${BOLD}Compression:${NC}"
echo "  1) lz4  — fast, good for large databases (recommended)"
echo "  2) zstd — slower, best compression ratio"
echo "  3) gz   — widely compatible"
echo "  4) none"
read -rp "  Select [1]: " comp_choice
case "${comp_choice:-1}" in
    1) COMPRESS_TYPE="lz4"  ;;
    2) COMPRESS_TYPE="zstd" ;;
    3) COMPRESS_TYPE="gz"   ;;
    4) COMPRESS_TYPE="none" ;;
    *) COMPRESS_TYPE="lz4"  ;;
esac
prompt COMPRESS_LEVEL "Compression level" "6"

prompt RETENTION_FULL "Keep N full backups" "3"
prompt RETENTION_DIFF "Keep N diff backups per full" "7"

SSH_CMD="ssh -p ${SSH_PORT} -o StrictHostKeyChecking=accept-new ${SSH_USER}@${SSH_HOST}"

# ─── Test SSH ─────────────────────────────────────────────────

echo ""
log "Testing SSH connection to ${SSH_USER}@${SSH_HOST}:${SSH_PORT}..."

if ! ${SSH_CMD} "echo 'SSH OK'" 2>/dev/null; then
    err "Cannot SSH to ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
    echo ""
    echo "  Make sure you can SSH to the server:"
    echo "    ssh -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST}"
    echo ""
    echo "  If using key-based auth, ensure your key is added:"
    echo "    ssh-copy-id -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST}"
    exit 1
fi
success "SSH connection OK"

# ─── Detect OS on remote ─────────────────────────────────────

log "Detecting remote OS..."
REMOTE_OS=$(${SSH_CMD} "cat /etc/os-release 2>/dev/null | grep '^ID=' | cut -d= -f2 | tr -d '\"'" 2>/dev/null || echo "unknown")
REMOTE_OS_LIKE=$(${SSH_CMD} "cat /etc/os-release 2>/dev/null | grep '^ID_LIKE=' | cut -d= -f2 | tr -d '\"'" 2>/dev/null || echo "")
log "Remote OS: ${REMOTE_OS} (${REMOTE_OS_LIKE})"

# ─── Install pgBackRest on remote ────────────────────────────

log "Installing pgBackRest on ${SSH_HOST}..."

INSTALL_CMD=""
case "${REMOTE_OS}" in
    ubuntu|debian)
        INSTALL_CMD="apt-get update -qq && apt-get install -y -qq pgbackrest"
        ;;
    centos|rhel|rocky|almalinux|ol)
        INSTALL_CMD="yum install -y pgbackrest || dnf install -y pgbackrest"
        ;;
    fedora)
        INSTALL_CMD="dnf install -y pgbackrest"
        ;;
    amzn)
        INSTALL_CMD="yum install -y pgbackrest || amazon-linux-extras install -y pgbackrest"
        ;;
    *)
        if echo "${REMOTE_OS_LIKE}" | grep -qi "debian\|ubuntu"; then
            INSTALL_CMD="apt-get update -qq && apt-get install -y -qq pgbackrest"
        elif echo "${REMOTE_OS_LIKE}" | grep -qi "rhel\|centos\|fedora"; then
            INSTALL_CMD="yum install -y pgbackrest || dnf install -y pgbackrest"
        else
            err "Unsupported OS: ${REMOTE_OS}"
            echo "  Install pgBackRest manually on ${SSH_HOST}:"
            echo "    https://pgbackrest.org/user-guide.html"
            exit 1
        fi
        ;;
esac

if ${SSH_CMD} "command -v pgbackrest" &>/dev/null; then
    REMOTE_PBR_VER=$(${SSH_CMD} "pgbackrest version" 2>/dev/null)
    success "pgBackRest already installed: ${REMOTE_PBR_VER}"
else
    if [[ "${SSH_USER}" == "root" ]]; then
        ${SSH_CMD} "${INSTALL_CMD}"
    else
        ${SSH_CMD} "sudo ${INSTALL_CMD}"
    fi
    success "pgBackRest installed: $(${SSH_CMD} "pgbackrest version" 2>/dev/null)"
fi

# ─── Create directories on remote ────────────────────────────

log "Creating directories on remote..."

${SSH_CMD} "
    $([ "${SSH_USER}" != "root" ] && echo "sudo") mkdir -p '${BACKUP_DIR}' '${LOG_DIR}'
    $([ "${SSH_USER}" != "root" ] && echo "sudo") chown -R postgres:postgres '${BACKUP_DIR}' '${LOG_DIR}'
    $([ "${SSH_USER}" != "root" ] && echo "sudo") chmod 750 '${BACKUP_DIR}' '${LOG_DIR}'
"
success "Directories created: ${BACKUP_DIR}, ${LOG_DIR}"

# ─── Generate pgbackrest.conf on remote ──────────────────────

log "Writing pgBackRest config on remote..."

PGBR_CONF="[global]
repo1-path=${BACKUP_DIR}
repo1-retention-full=${RETENTION_FULL}
repo1-retention-diff=${RETENTION_DIFF}

compress-type=${COMPRESS_TYPE}
compress-level=${COMPRESS_LEVEL}

process-max=${PROCESS_MAX}
buffer-size=4194304

log-level-console=info
log-level-file=detail
log-path=${LOG_DIR}

delta=y

protocol-timeout=3600
db-timeout=600

[${STANZA}]
pg1-path=${PG_DATA}
pg1-port=${PG_PORT}
pg1-user=${PG_USER}
"

${SSH_CMD} "
    $([ "${SSH_USER}" != "root" ] && echo "sudo") tee /etc/pgbackrest/pgbackrest.conf > /dev/null <<'REMOTEEOF'
${PGBR_CONF}
REMOTEEOF
    $([ "${SSH_USER}" != "root" ] && echo "sudo") chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
    $([ "${SSH_USER}" != "root" ] && echo "sudo") chmod 640 /etc/pgbackrest/pgbackrest.conf
"
success "Config written to /etc/pgbackrest/pgbackrest.conf"

# ─── Configure PostgreSQL WAL archiving ──────────────────────

log "Configuring PostgreSQL WAL archiving..."

# Check current archive_mode
ARCHIVE_MODE=$(${SSH_CMD} "sudo -u postgres psql -p ${PG_PORT} -tAc \"SHOW archive_mode;\"" 2>/dev/null | tr -d '[:space:]')
ARCHIVE_CMD=$(${SSH_CMD} "sudo -u postgres psql -p ${PG_PORT} -tAc \"SHOW archive_command;\"" 2>/dev/null | tr -d '[:space:]')
WAL_LEVEL=$(${SSH_CMD} "sudo -u postgres psql -p ${PG_PORT} -tAc \"SHOW wal_level;\"" 2>/dev/null | tr -d '[:space:]')

NEEDS_RESTART=false

if [[ "$ARCHIVE_MODE" == "on" && "$ARCHIVE_CMD" == *"pgbackrest"* && "$WAL_LEVEL" == "replica" ]]; then
    success "WAL archiving already configured for pgBackRest"
else
    warn "PostgreSQL needs WAL archiving configured."
    echo ""
    echo "  Current settings:"
    echo "    wal_level       = ${WAL_LEVEL:-unknown}"
    echo "    archive_mode    = ${ARCHIVE_MODE:-unknown}"
    echo "    archive_command = ${ARCHIVE_CMD:-unknown}"
    echo ""
    echo "  Required settings:"
    echo "    wal_level       = replica"
    echo "    archive_mode    = on"
    echo "    archive_command = 'pgbackrest --stanza=${STANZA} archive-push %p'"
    echo ""

    read -rp "  Apply these settings via ALTER SYSTEM? [Y/n]: " apply
    if [[ ! "$apply" =~ ^[Nn] ]]; then
        ${SSH_CMD} "sudo -u postgres psql -p ${PG_PORT} <<'EOSQL'
ALTER SYSTEM SET wal_level = 'replica';
ALTER SYSTEM SET archive_mode = 'on';
ALTER SYSTEM SET archive_command = 'pgbackrest --stanza=${STANZA} archive-push %p';
ALTER SYSTEM SET max_wal_senders = 5;
EOSQL
"
        NEEDS_RESTART=true
        success "Settings applied via ALTER SYSTEM"
    fi
fi

# ─── Restart PostgreSQL if needed ─────────────────────────────

if [[ "$NEEDS_RESTART" == "true" ]]; then
    echo ""
    warn "PostgreSQL MUST be restarted for archive_mode to take effect."
    read -rp "  Restart PostgreSQL now? [Y/n]: " do_restart
    if [[ ! "$do_restart" =~ ^[Nn] ]]; then
        log "Restarting PostgreSQL..."
        ${SSH_CMD} "
            if command -v systemctl &>/dev/null && systemctl list-units --type=service 2>/dev/null | grep -q postgresql; then
                SVC=\$(systemctl list-units --type=service 2>/dev/null | grep postgresql | awk '{print \$1}' | head -1)
                $([ "${SSH_USER}" != "root" ] && echo "sudo") systemctl restart \"\$SVC\"
            else
                sudo -u postgres pg_ctl -D '${PG_DATA}' restart -m fast
            fi
        "
        sleep 3

        # Verify it came back
        if ${SSH_CMD} "sudo -u postgres pg_isready -p ${PG_PORT}" &>/dev/null; then
            success "PostgreSQL restarted"
        else
            err "PostgreSQL did not come back. Check logs on ${SSH_HOST}."
            exit 1
        fi
    else
        echo ""
        echo "  Restart PostgreSQL manually before proceeding:"
        echo "    sudo systemctl restart postgresql"
        echo ""
        echo "  Then re-run this script."
        exit 0
    fi
fi

# ─── Create stanza ───────────────────────────────────────────

log "Creating pgBackRest stanza '${STANZA}'..."

${SSH_CMD} "sudo -u postgres pgbackrest --stanza='${STANZA}' stanza-create"
success "Stanza created"

log "Verifying stanza (this also tests WAL archiving)..."
${SSH_CMD} "sudo -u postgres pgbackrest --stanza='${STANZA}' check"
success "Stanza verified — WAL archiving is working"

# ─── Save local config ───────────────────────────────────────

log "Saving configuration to ${CONFIG_FILE}..."

cat > "${CONFIG_FILE}" <<EOF
# PostgreSQL Remote Backup Config
# Generated by setup.sh on $(date '+%Y-%m-%d %H:%M:%S')
# ───────────────────────────────────────────
SSH_HOST="${SSH_HOST}"
SSH_USER="${SSH_USER}"
SSH_PORT="${SSH_PORT}"
PG_PORT="${PG_PORT}"
PG_USER="${PG_USER}"
PG_DATA="${PG_DATA}"
STANZA="${STANZA}"
BACKUP_DIR="${BACKUP_DIR}"
LOG_DIR="${LOG_DIR}"
PROCESS_MAX="${PROCESS_MAX}"
COMPRESS_TYPE="${COMPRESS_TYPE}"
EOF

chmod 600 "${CONFIG_FILE}"
success "Config saved"

# ─── Done ─────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Setup Complete${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  Remote server : ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
echo "  PostgreSQL    : port ${PG_PORT}, data at ${PG_DATA}"
echo "  Stanza        : ${STANZA}"
echo "  Backups stored: ${SSH_HOST}:${BACKUP_DIR}"
echo "  Local config  : ${CONFIG_FILE}"
echo ""
echo "  Next steps:"
echo "    bash backup.sh full          # Take first full backup"
echo "    bash backup.sh diff          # Differential backup"
echo "    bash backup.sh incr          # Incremental backup"
echo "    bash backup.sh info          # View backups"
echo "    bash restore.sh --help       # Restore options"
echo ""
