#!/usr/bin/env bash
# ============================================================
#  setup.sh — Dedicated Backup Host setup for pgBackRest
#
#  Architecture:
#    - pgBackRest runs HERE on the backup host
#    - Backups are stored HERE on the backup host
#    - A thin pgBackRest agent is installed on the PG server
#      (only for WAL archive-push/archive-get via SSH)
#    - SSH keys enable bidirectional communication
#
#  What this does:
#    1. Installs pgBackRest on THIS machine (backup host)
#    2. SSHes to the PG server, installs thin pgBackRest agent
#    3. Sets up SSH keys between backup host <-> PG server
#    4. Configures pgbackrest.conf on BOTH hosts
#    5. Configures WAL archiving on PG server (archive-push to backup host)
#    6. Creates and verifies the backup stanza
#
#  Run this ONCE from your dedicated backup server.
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

# ─── Collect details ─────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  PostgreSQL Backup — Dedicated Backup Host Setup${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Architecture:"
echo "    Backup Host (this machine) ← stores backups + runs pgBackRest"
echo "    PostgreSQL Server          ← thin agent for WAL shipping only"
echo ""

echo -e "${BOLD}Remote PostgreSQL Server:${NC}"
prompt  PG_HOST         "PostgreSQL server hostname or IP"
prompt  SSH_USER        "SSH user on PG server (must have sudo)"   "root"
prompt  SSH_PORT        "SSH port on PG server"                    "22"
echo ""
echo -e "${BOLD}PostgreSQL Settings:${NC}"
prompt  PG_PORT         "PostgreSQL port"             "5432"
prompt  PG_DB_USER      "PostgreSQL superuser"        "postgres"
prompt  PG_DATA         "PGDATA directory"            "/var/lib/postgresql/16/main"
echo ""
echo -e "${BOLD}Backup Host Settings (this machine):${NC}"
prompt  BACKUP_USER     "Local user to run pgBackRest"  "$(whoami)"
prompt  BACKUP_DIR      "Local backup repository path"  "/var/lib/pgbackrest"
prompt  BACKUP_LOG_DIR  "Local log directory"           "/var/log/pgbackrest"
prompt  STANZA          "Stanza name"                   "main"
prompt  PROCESS_MAX     "Parallel workers"              "4"
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

BACKUP_HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [[ -z "$BACKUP_HOST_IP" ]]; then
    BACKUP_HOST_IP=$(hostname 2>/dev/null)
fi
echo ""
prompt BACKUP_HOST_ADDR "This machine's IP/hostname (as seen from PG server)" "$BACKUP_HOST_IP"

SSH_CMD="ssh -p ${SSH_PORT} -o StrictHostKeyChecking=accept-new ${SSH_USER}@${PG_HOST}"

# ─── Test SSH to PG server ───────────────────────────────────

echo ""
log "Testing SSH connection to ${SSH_USER}@${PG_HOST}:${SSH_PORT}..."

if ! ${SSH_CMD} "echo 'SSH OK'" 2>/dev/null; then
    err "Cannot SSH to ${SSH_USER}@${PG_HOST}:${SSH_PORT}"
    echo ""
    echo "  Make sure you can SSH to the server:"
    echo "    ssh -p ${SSH_PORT} ${SSH_USER}@${PG_HOST}"
    echo ""
    echo "  If using key-based auth, ensure your key is added:"
    echo "    ssh-copy-id -p ${SSH_PORT} ${SSH_USER}@${PG_HOST}"
    exit 1
fi
success "SSH connection OK"

# ─── Detect OS on both hosts ─────────────────────────────────

detect_os() {
    local os os_like
    os=$(cat /etc/os-release 2>/dev/null | grep '^ID=' | cut -d= -f2 | tr -d '"' || echo "unknown")
    os_like=$(cat /etc/os-release 2>/dev/null | grep '^ID_LIKE=' | cut -d= -f2 | tr -d '"' || echo "")
    echo "${os}|${os_like}"
}

install_cmd_for_os() {
    local os="$1" os_like="$2"
    case "${os}" in
        ubuntu|debian)
            echo "apt-get update -qq && apt-get install -y -qq pgbackrest"
            ;;
        centos|rhel|rocky|almalinux|ol)
            echo "yum install -y pgbackrest || dnf install -y pgbackrest"
            ;;
        fedora)
            echo "dnf install -y pgbackrest"
            ;;
        amzn)
            echo "yum install -y pgbackrest || amazon-linux-extras install -y pgbackrest"
            ;;
        *)
            if echo "${os_like}" | grep -qi "debian\|ubuntu"; then
                echo "apt-get update -qq && apt-get install -y -qq pgbackrest"
            elif echo "${os_like}" | grep -qi "rhel\|centos\|fedora"; then
                echo "yum install -y pgbackrest || dnf install -y pgbackrest"
            else
                echo ""
            fi
            ;;
    esac
}

log "Detecting local OS..."
LOCAL_OS_INFO=$(detect_os)
LOCAL_OS=$(echo "$LOCAL_OS_INFO" | cut -d'|' -f1)
LOCAL_OS_LIKE=$(echo "$LOCAL_OS_INFO" | cut -d'|' -f2)
log "Local OS: ${LOCAL_OS}"

log "Detecting remote OS..."
REMOTE_OS=$(${SSH_CMD} "cat /etc/os-release 2>/dev/null | grep '^ID=' | cut -d= -f2 | tr -d '\"'" 2>/dev/null || echo "unknown")
REMOTE_OS_LIKE=$(${SSH_CMD} "cat /etc/os-release 2>/dev/null | grep '^ID_LIKE=' | cut -d= -f2 | tr -d '\"'" 2>/dev/null || echo "")
log "Remote OS: ${REMOTE_OS}"

# ═══════════════════════════════════════════════════════════════
#  STEP 1: Install pgBackRest on THIS backup host
# ═══════════════════════════════════════════════════════════════

echo ""
log "Step 1: Installing pgBackRest on THIS backup host..."

if command -v pgbackrest &>/dev/null; then
    LOCAL_PBR_VER=$(pgbackrest version 2>/dev/null)
    success "pgBackRest already installed locally: ${LOCAL_PBR_VER}"
else
    LOCAL_INSTALL=$(install_cmd_for_os "$LOCAL_OS" "$LOCAL_OS_LIKE")
    if [[ -z "$LOCAL_INSTALL" ]]; then
        err "Cannot auto-install pgBackRest on ${LOCAL_OS}"
        echo "  Install pgBackRest manually: https://pgbackrest.org/user-guide.html"
        exit 1
    fi
    echo "  Running: sudo ${LOCAL_INSTALL}"
    sudo bash -c "${LOCAL_INSTALL}"
    success "pgBackRest installed locally: $(pgbackrest version 2>/dev/null)"
fi

# ═══════════════════════════════════════════════════════════════
#  STEP 2: Install pgBackRest agent on PG server
# ═══════════════════════════════════════════════════════════════

echo ""
log "Step 2: Installing pgBackRest on PG server (thin agent)..."

if ${SSH_CMD} "command -v pgbackrest" &>/dev/null; then
    REMOTE_PBR_VER=$(${SSH_CMD} "pgbackrest version" 2>/dev/null)
    success "pgBackRest already installed on PG server: ${REMOTE_PBR_VER}"
else
    REMOTE_INSTALL=$(install_cmd_for_os "$REMOTE_OS" "$REMOTE_OS_LIKE")
    if [[ -z "$REMOTE_INSTALL" ]]; then
        err "Cannot auto-install pgBackRest on ${REMOTE_OS}"
        echo "  Install pgBackRest manually on ${PG_HOST}"
        exit 1
    fi
    if [[ "${SSH_USER}" == "root" ]]; then
        ${SSH_CMD} "${REMOTE_INSTALL}"
    else
        ${SSH_CMD} "sudo ${REMOTE_INSTALL}"
    fi
    success "pgBackRest installed on PG server: $(${SSH_CMD} "pgbackrest version" 2>/dev/null)"
fi

# ═══════════════════════════════════════════════════════════════
#  STEP 3: Set up SSH keys for bidirectional access
# ═══════════════════════════════════════════════════════════════

echo ""
log "Step 3: Setting up SSH keys..."

# --- Backup host (BACKUP_USER) → PG server (postgres) ---
log "Setting up SSH: ${BACKUP_USER}@backup-host → postgres@${PG_HOST}"

LOCAL_KEY="/home/${BACKUP_USER}/.ssh/id_rsa"
if [[ "$BACKUP_USER" == "root" ]]; then
    LOCAL_KEY="/root/.ssh/id_rsa"
elif [[ "$BACKUP_USER" == "$(whoami)" ]]; then
    LOCAL_KEY="${HOME}/.ssh/id_rsa"
fi

# Generate key for backup user if not exists
if [[ ! -f "$LOCAL_KEY" ]]; then
    log "Generating SSH key for ${BACKUP_USER}..."
    sudo -u "${BACKUP_USER}" ssh-keygen -t rsa -b 4096 -N "" -f "$LOCAL_KEY" -C "pgbackrest@backup-host" 2>/dev/null || \
        ssh-keygen -t rsa -b 4096 -N "" -f "$LOCAL_KEY" -C "pgbackrest@backup-host"
    success "SSH key generated: ${LOCAL_KEY}"
else
    success "SSH key exists: ${LOCAL_KEY}"
fi

LOCAL_PUBKEY=$(cat "${LOCAL_KEY}.pub")

# Add backup host's key to postgres@PG_SERVER authorized_keys
${SSH_CMD} "
    $([ "${SSH_USER}" != "root" ] && echo "sudo") mkdir -p ~postgres/.ssh
    $([ "${SSH_USER}" != "root" ] && echo "sudo") chmod 700 ~postgres/.ssh
    $([ "${SSH_USER}" != "root" ] && echo "sudo") touch ~postgres/.ssh/authorized_keys
    if ! $([ "${SSH_USER}" != "root" ] && echo "sudo") grep -qF '${LOCAL_PUBKEY}' ~postgres/.ssh/authorized_keys 2>/dev/null; then
        echo '${LOCAL_PUBKEY}' | $([ "${SSH_USER}" != "root" ] && echo "sudo") tee -a ~postgres/.ssh/authorized_keys > /dev/null
    fi
    $([ "${SSH_USER}" != "root" ] && echo "sudo") chmod 600 ~postgres/.ssh/authorized_keys
    $([ "${SSH_USER}" != "root" ] && echo "sudo") chown -R postgres:postgres ~postgres/.ssh
"
success "${BACKUP_USER}@backup-host → postgres@${PG_HOST} SSH key installed"

# --- PG server (postgres) → Backup host (BACKUP_USER) ---
log "Setting up SSH: postgres@${PG_HOST} → ${BACKUP_USER}@${BACKUP_HOST_ADDR}"

# Generate key for postgres on PG server if not exists
REMOTE_PUBKEY=$(${SSH_CMD} "
    if [ ! -f ~postgres/.ssh/id_rsa ]; then
        $([ "${SSH_USER}" != "root" ] && echo "sudo") su - postgres -c \"ssh-keygen -t rsa -b 4096 -N '' -f ~postgres/.ssh/id_rsa -C 'postgres@pg-server'\" 2>/dev/null
    fi
    $([ "${SSH_USER}" != "root" ] && echo "sudo") cat ~postgres/.ssh/id_rsa.pub
" 2>/dev/null)

# Add PG server's postgres key to backup host's authorized_keys
LOCAL_AUTH_KEYS="${HOME}/.ssh/authorized_keys"
if [[ "$BACKUP_USER" == "root" ]]; then
    LOCAL_AUTH_KEYS="/root/.ssh/authorized_keys"
fi
mkdir -p "$(dirname "$LOCAL_AUTH_KEYS")"
touch "$LOCAL_AUTH_KEYS"
if ! grep -qF "$REMOTE_PUBKEY" "$LOCAL_AUTH_KEYS" 2>/dev/null; then
    echo "$REMOTE_PUBKEY" >> "$LOCAL_AUTH_KEYS"
fi
chmod 600 "$LOCAL_AUTH_KEYS"
success "postgres@${PG_HOST} → ${BACKUP_USER}@${BACKUP_HOST_ADDR} SSH key installed"

# Test both directions
log "Testing SSH: ${BACKUP_USER} → postgres@${PG_HOST}..."
if ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new -i "${LOCAL_KEY}" "postgres@${PG_HOST}" "echo 'OK'" &>/dev/null; then
    success "Bidirectional SSH: backup → PG server works"
else
    warn "SSH as postgres@${PG_HOST} may need manual verification"
    echo "  Test with: ssh -p ${SSH_PORT} -i ${LOCAL_KEY} postgres@${PG_HOST}"
fi

# ═══════════════════════════════════════════════════════════════
#  STEP 4: Create directories
# ═══════════════════════════════════════════════════════════════

echo ""
log "Step 4: Creating directories..."

# Local (backup host)
sudo mkdir -p "${BACKUP_DIR}" "${BACKUP_LOG_DIR}" /etc/pgbackrest
sudo chown -R "${BACKUP_USER}:$(id -gn "${BACKUP_USER}")" "${BACKUP_DIR}" "${BACKUP_LOG_DIR}"
sudo chmod 750 "${BACKUP_DIR}" "${BACKUP_LOG_DIR}"
success "Local directories: ${BACKUP_DIR}, ${BACKUP_LOG_DIR}"

# Remote (PG server) — only needs log dir and config dir
${SSH_CMD} "
    $([ "${SSH_USER}" != "root" ] && echo "sudo") mkdir -p /var/log/pgbackrest /etc/pgbackrest
    $([ "${SSH_USER}" != "root" ] && echo "sudo") chown -R postgres:postgres /var/log/pgbackrest /etc/pgbackrest
"
success "Remote directories created"

# ═══════════════════════════════════════════════════════════════
#  STEP 5: Write pgbackrest.conf on BOTH hosts
# ═══════════════════════════════════════════════════════════════

echo ""
log "Step 5: Writing pgBackRest config on both hosts..."

# --- Config on BACKUP HOST ---
# pgBackRest on backup host knows: repo is local, PG is remote
LOCAL_CONF="[global]
repo1-path=${BACKUP_DIR}
repo1-retention-full=${RETENTION_FULL}
repo1-retention-diff=${RETENTION_DIFF}

compress-type=${COMPRESS_TYPE}
compress-level=${COMPRESS_LEVEL}

process-max=${PROCESS_MAX}
buffer-size=4194304

log-level-console=info
log-level-file=detail
log-path=${BACKUP_LOG_DIR}

delta=y

protocol-timeout=3600
db-timeout=600

[${STANZA}]
pg1-host=${PG_HOST}
pg1-host-user=postgres
pg1-port=${PG_PORT}
pg1-path=${PG_DATA}
"

sudo tee /etc/pgbackrest/pgbackrest.conf > /dev/null <<EOF
${LOCAL_CONF}
EOF
sudo chown "${BACKUP_USER}:$(id -gn "${BACKUP_USER}")" /etc/pgbackrest/pgbackrest.conf
sudo chmod 640 /etc/pgbackrest/pgbackrest.conf
success "Backup host config: /etc/pgbackrest/pgbackrest.conf"

# --- Config on PG SERVER ---
# pgBackRest on PG server knows: repo is on backup host (remote), PG data is local
REMOTE_CONF="[global]
repo1-host=${BACKUP_HOST_ADDR}
repo1-host-user=${BACKUP_USER}
repo1-path=${BACKUP_DIR}

log-level-console=info
log-level-file=detail
log-path=/var/log/pgbackrest

[${STANZA}]
pg1-path=${PG_DATA}
pg1-port=${PG_PORT}
"

${SSH_CMD} "
    $([ "${SSH_USER}" != "root" ] && echo "sudo") tee /etc/pgbackrest/pgbackrest.conf > /dev/null <<'REMOTEEOF'
${REMOTE_CONF}
REMOTEEOF
    $([ "${SSH_USER}" != "root" ] && echo "sudo") chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
    $([ "${SSH_USER}" != "root" ] && echo "sudo") chmod 640 /etc/pgbackrest/pgbackrest.conf
"
success "PG server config: /etc/pgbackrest/pgbackrest.conf"

# ═══════════════════════════════════════════════════════════════
#  STEP 6: Configure PostgreSQL WAL archiving
# ═══════════════════════════════════════════════════════════════

echo ""
log "Step 6: Configuring WAL archiving on PG server..."

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
    echo "  NOTE: archive-push on the PG server will SSH to this backup host"
    echo "        to store WAL files here at: ${BACKUP_DIR}"
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

        if ${SSH_CMD} "sudo -u postgres pg_isready -p ${PG_PORT}" &>/dev/null; then
            success "PostgreSQL restarted"
        else
            err "PostgreSQL did not come back. Check logs on ${PG_HOST}."
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

# ═══════════════════════════════════════════════════════════════
#  STEP 7: Create stanza (run from BACKUP HOST)
# ═══════════════════════════════════════════════════════════════

echo ""
log "Step 7: Creating pgBackRest stanza '${STANZA}' from backup host..."

pgbackrest --stanza="${STANZA}" stanza-create
success "Stanza created"

log "Verifying stanza (tests backup host → PG server connectivity + WAL archiving)..."
pgbackrest --stanza="${STANZA}" check
success "Stanza verified — backup host can reach PG server, WAL archiving works"

# ═══════════════════════════════════════════════════════════════
#  Save local config for backup.sh / restore.sh
# ═══════════════════════════════════════════════════════════════

log "Saving configuration to ${CONFIG_FILE}..."

cat > "${CONFIG_FILE}" <<EOF
# PostgreSQL Dedicated Backup Host Config
# Generated by setup.sh on $(date '+%Y-%m-%d %H:%M:%S')
# ───────────────────────────────────────────
# PG Server
PG_HOST="${PG_HOST}"
SSH_USER="${SSH_USER}"
SSH_PORT="${SSH_PORT}"
PG_PORT="${PG_PORT}"
PG_DB_USER="${PG_DB_USER}"
PG_DATA="${PG_DATA}"

# Backup Host (this machine)
BACKUP_USER="${BACKUP_USER}"
BACKUP_DIR="${BACKUP_DIR}"
BACKUP_LOG_DIR="${BACKUP_LOG_DIR}"
BACKUP_HOST_ADDR="${BACKUP_HOST_ADDR}"

# pgBackRest
STANZA="${STANZA}"
PROCESS_MAX="${PROCESS_MAX}"
COMPRESS_TYPE="${COMPRESS_TYPE}"
EOF

chmod 600 "${CONFIG_FILE}"
success "Config saved"

# ─── Done ─────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Setup Complete — Dedicated Backup Host${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Backup Host (this machine):"
echo "    pgBackRest    : $(pgbackrest version 2>/dev/null)"
echo "    Backups at    : ${BACKUP_DIR}"
echo "    Config        : /etc/pgbackrest/pgbackrest.conf"
echo ""
echo "  PostgreSQL Server:"
echo "    Host          : ${PG_HOST}"
echo "    PGDATA        : ${PG_DATA}"
echo "    WAL archiving : archive-push → ${BACKUP_HOST_ADDR}:${BACKUP_DIR}"
echo ""
echo "  Next steps:"
echo "    bash backup.sh full          # Take first full backup"
echo "    bash backup.sh diff          # Differential backup"
echo "    bash backup.sh incr          # Incremental backup"
echo "    bash backup.sh info          # View backups"
echo "    bash restore.sh --help       # Restore options"
echo ""
