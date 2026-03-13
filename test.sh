#!/usr/bin/env bash
# ============================================================
#  test.sh — End-to-end test of backup.sh and restore.sh
#
#  Spins up a PostgreSQL Docker container, installs pg tools in a
#  client container, creates test data, runs all backup types,
#  restores, and validates.
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[TEST]${NC} $*"; }
success() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail()    { echo -e "${RED}[FAIL]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET_NAME="pgtest_net_$$"
PG_CONTAINER="pgtest_server_$$"
CLIENT_CONTAINER="pgtest_client_$$"
PG_PASS="testpass123"
PG_USER="postgres"
PASSED=0
FAILED=0

cleanup() {
    log "Cleaning up..."
    docker rm -f "$PG_CONTAINER" "$CLIENT_CONTAINER" 2>/dev/null || true
    docker network rm "$NET_NAME" 2>/dev/null || true
}
trap cleanup EXIT

# ─── Create network and start PG server ───────────────────────

log "Creating Docker network..."
docker network create "$NET_NAME" >/dev/null

log "Starting PostgreSQL server..."
docker run -d --name "$PG_CONTAINER" --network "$NET_NAME" \
    -e POSTGRES_PASSWORD="$PG_PASS" \
    postgres:16 \
    -c wal_level=replica \
    -c max_wal_senders=5 >/dev/null

# ─── Start client container with pg tools + scripts ───────────

log "Starting client container with PostgreSQL tools..."
docker run -d --name "$CLIENT_CONTAINER" --network "$NET_NAME" \
    -v "${SCRIPT_DIR}:/scripts" \
    postgres:16 \
    tail -f /dev/null >/dev/null

# Wait for PG server
log "Waiting for PostgreSQL server..."
for i in $(seq 1 30); do
    if docker exec "$PG_CONTAINER" pg_isready -U postgres &>/dev/null; then
        break
    fi
    if [[ $i -eq 30 ]]; then fail "PostgreSQL did not start"; exit 1; fi
    sleep 1
done

# Allow replication from any host (needed for pg_basebackup)
log "Enabling replication access..."
docker exec "$PG_CONTAINER" bash -c "echo 'host replication all all trust' >> /var/lib/postgresql/data/pg_hba.conf"
docker exec -u postgres "$PG_CONTAINER" pg_ctl reload -D /var/lib/postgresql/data
sleep 1

success "PostgreSQL is ready"

# Helper: run command in client container
run() {
    docker exec -e PGPASSWORD="$PG_PASS" "$CLIENT_CONTAINER" "$@"
}

# ─── Create test data ────────────────────────────────────────

log "Creating test data..."

run psql -h "$PG_CONTAINER" -U "$PG_USER" -d postgres -c "CREATE DATABASE testdb;"

run psql -h "$PG_CONTAINER" -U "$PG_USER" -d testdb -c "
CREATE TABLE employees (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(200),
    department VARCHAR(50),
    salary NUMERIC(10,2),
    created_at TIMESTAMP DEFAULT NOW()
);
INSERT INTO employees (name, email, department, salary)
SELECT
    'Employee_' || i,
    'emp' || i || '@test.com',
    CASE (i % 4)
        WHEN 0 THEN 'Engineering'
        WHEN 1 THEN 'Sales'
        WHEN 2 THEN 'Marketing'
        WHEN 3 THEN 'Operations'
    END,
    30000 + (random() * 70000)::int
FROM generate_series(1, 1000) AS i;

CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    employee_id INT REFERENCES employees(id),
    product VARCHAR(100),
    amount NUMERIC(10,2),
    order_date DATE DEFAULT CURRENT_DATE
);
INSERT INTO orders (employee_id, product, amount)
SELECT
    (random() * 999 + 1)::int,
    'Product_' || (random() * 50 + 1)::int,
    (random() * 1000)::numeric(10,2)
FROM generate_series(1, 5000);
"

ORIG_EMP=$(run psql -h "$PG_CONTAINER" -U "$PG_USER" -d testdb -tAc "SELECT count(*) FROM employees;")
ORIG_ORD=$(run psql -h "$PG_CONTAINER" -U "$PG_USER" -d testdb -tAc "SELECT count(*) FROM orders;")
ORIG_SAL=$(run psql -h "$PG_CONTAINER" -U "$PG_USER" -d testdb -tAc "SELECT sum(salary)::bigint FROM employees;")

success "Test data: ${ORIG_EMP} employees, ${ORIG_ORD} orders"

# ─── Test 1: basebackup ──────────────────────────────────────

echo ""
echo -e "${BOLD}═══ Test 1: basebackup (full physical) ═══${NC}"

run bash /scripts/backup.sh \
    -H "$PG_CONTAINER" -U "$PG_USER" -W "$PG_PASS" \
    -t basebackup -o /tmp/backups -c gzip

BB_FILE=$(run find /tmp/backups -maxdepth 1 -type d -name "basebackup_*" -print | head -1)
if [[ -n "$BB_FILE" ]]; then
    BB_SIZE=$(run du -sh "$BB_FILE" | awk '{print $1}')
    success "Test 1: basebackup created (${BB_SIZE})"
    PASSED=$((PASSED + 1))
    # Check metadata
    if run test -f "${BB_FILE}.meta"; then
        success "Test 1: metadata file created"
        PASSED=$((PASSED + 1))
    else
        fail "Test 1: metadata missing"
        FAILED=$((FAILED + 1))
    fi
else
    fail "Test 1: basebackup not found"
    FAILED=$((FAILED + 1))
    FAILED=$((FAILED + 1))
fi

# ─── Test 2: pg_dump ──────────────────────────────────────────

echo ""
echo -e "${BOLD}═══ Test 2: dump (single database) ═══${NC}"

run bash /scripts/backup.sh \
    -H "$PG_CONTAINER" -U "$PG_USER" -W "$PG_PASS" \
    -t dump -d testdb -o /tmp/backups

DUMP_FILE=$(run find /tmp/backups -name "dump_testdb_*.dump" -print | head -1)
if [[ -n "$DUMP_FILE" ]]; then
    D_SIZE=$(run du -sh "$DUMP_FILE" | awk '{print $1}')
    success "Test 2: dump created (${D_SIZE})"
    PASSED=$((PASSED + 1))
else
    fail "Test 2: dump not found"
    FAILED=$((FAILED + 1))
fi

# ─── Test 3: dumpall ──────────────────────────────────────────

echo ""
echo -e "${BOLD}═══ Test 3: dumpall (all databases) ═══${NC}"

run bash /scripts/backup.sh \
    -H "$PG_CONTAINER" -U "$PG_USER" -W "$PG_PASS" \
    -t dumpall -o /tmp/backups -c gzip

DA_FILE=$(run find /tmp/backups -name "dumpall_*.sql.gz" -print | head -1)
if [[ -n "$DA_FILE" ]]; then
    DA_SIZE=$(run du -sh "$DA_FILE" | awk '{print $1}')
    success "Test 3: dumpall created (${DA_SIZE})"
    PASSED=$((PASSED + 1))
else
    fail "Test 3: dumpall not found"
    FAILED=$((FAILED + 1))
fi

# ─── Test 4: list backups ────────────────────────────────────

echo ""
echo -e "${BOLD}═══ Test 4: list backups ═══${NC}"

LIST_OUT=$(run bash /scripts/restore.sh --list -o /tmp/backups 2>&1)
if echo "$LIST_OUT" | grep -q "basebackup" && echo "$LIST_OUT" | grep -q "dump"; then
    success "Test 4: list shows all backup types"
    PASSED=$((PASSED + 1))
else
    fail "Test 4: list output unexpected"
    echo "$LIST_OUT"
    FAILED=$((FAILED + 1))
fi

# ─── Test 5: restore dump to new database ─────────────────────

echo ""
echo -e "${BOLD}═══ Test 5: restore dump → new database ═══${NC}"

docker exec -i -e PGPASSWORD="$PG_PASS" "$CLIENT_CONTAINER" \
    bash /scripts/restore.sh \
    -f "$DUMP_FILE" \
    -H "$PG_CONTAINER" -U "$PG_USER" -W "$PG_PASS" \
    -d testdb_restored <<< "Y"

REST_EMP=$(run psql -h "$PG_CONTAINER" -U "$PG_USER" -d testdb_restored -tAc "SELECT count(*) FROM employees;" 2>/dev/null || echo "0")
REST_ORD=$(run psql -h "$PG_CONTAINER" -U "$PG_USER" -d testdb_restored -tAc "SELECT count(*) FROM orders;" 2>/dev/null || echo "0")
REST_SAL=$(run psql -h "$PG_CONTAINER" -U "$PG_USER" -d testdb_restored -tAc "SELECT sum(salary)::bigint FROM employees;" 2>/dev/null || echo "0")

echo ""
echo "  Original:  employees=${ORIG_EMP}  orders=${ORIG_ORD}  salary=${ORIG_SAL}"
echo "  Restored:  employees=${REST_EMP}  orders=${REST_ORD}  salary=${REST_SAL}"

if [[ "${REST_EMP// /}" == "${ORIG_EMP// /}" && "${REST_ORD// /}" == "${ORIG_ORD// /}" && "${REST_SAL// /}" == "${ORIG_SAL// /}" ]]; then
    success "Test 5: restored data matches perfectly"
    PASSED=$((PASSED + 1))
else
    fail "Test 5: data mismatch after restore"
    FAILED=$((FAILED + 1))
fi

# ─── Test 6: extract basebackup ──────────────────────────────

echo ""
echo -e "${BOLD}═══ Test 6: extract basebackup ═══${NC}"

docker exec -i -e PGPASSWORD="$PG_PASS" "$CLIENT_CONTAINER" \
    bash /scripts/restore.sh \
    -f "$BB_FILE" \
    --restore-dir /tmp/backups/extracted <<< "Y"

EXTRACT_COUNT=$(run sh -c "ls /tmp/backups/extracted/ 2>/dev/null | wc -l")
if [[ "$EXTRACT_COUNT" -gt 0 ]]; then
    success "Test 6: basebackup extracted (${EXTRACT_COUNT} items)"
    PASSED=$((PASSED + 1))
else
    fail "Test 6: extract directory empty"
    FAILED=$((FAILED + 1))
fi

# ─── Summary ──────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Test Results${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}Passed: ${PASSED}${NC}"
echo -e "  ${RED}Failed: ${FAILED}${NC}"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  ALL TESTS PASSED${NC}"
else
    echo -e "${RED}${BOLD}  SOME TESTS FAILED${NC}"
fi
echo ""

exit $FAILED
