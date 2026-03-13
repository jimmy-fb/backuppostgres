# backuppostgres

Simple PostgreSQL backup & restore scripts. Uses standard PostgreSQL tools (`pg_basebackup`, `pg_dump`, `pg_restore`) — no extra software needed on the database server.

```
┌──────────────────────────┐     PostgreSQL     ┌──────────────────────────┐
│  YOUR MACHINE            │     protocol       │  REMOTE PG SERVER        │
│  (laptop / backup host)  │ ──────────────────>│                          │
│                          │     (port 5432)    │  Nothing to install.     │
│  bash backup.sh ...      │ <──────────────────│  Just PostgreSQL.        │
└──────────────────────────┘                    └──────────────────────────┘
```

**No SSH. No pgBackRest. No packages to install on the server.**

---

## Step-by-Step: Back Up a Remote PostgreSQL Server

### Step 1: Install PostgreSQL client tools (one time)

You only need client tools on **your machine** (the machine running the scripts). Nothing is installed on the remote server.

```bash
# macOS
brew install postgresql

# Ubuntu / Debian
sudo apt-get install postgresql-client

# RHEL / CentOS / Amazon Linux
sudo yum install postgresql
```

Verify:
```bash
psql --version
pg_basebackup --version
pg_dump --version
```

### Step 2: Clone this repo

```bash
git clone https://github.com/jimmy-fb/backuppostgres.git
cd backuppostgres
```

### Step 3: Make sure the remote server allows connections

On the **remote PostgreSQL server**, check `pg_hba.conf` has a line allowing your IP:

```
# For regular connections (pg_dump, pg_dumpall):
host    all             all             <your-ip>/32            md5

# For physical backups (pg_basebackup) — also needs replication permission:
host    replication     all             <your-ip>/32            md5
```

After editing, reload PostgreSQL on the server:
```bash
sudo systemctl reload postgresql
```

> If you only need `dump` or `dumpall` backups, you don't need the replication line.

### Step 4: Take a backup

#### Option A: Full physical backup (entire cluster)

```bash
bash backup.sh -H <server-ip> -U postgres -W <password>
```

Example:
```bash
bash backup.sh -H 10.0.0.5 -U postgres -W mysecretpass
```

This creates a directory like `./backups/basebackup_20260313_143022/` containing compressed tar files.

#### Option B: SQL dump of a single database

```bash
bash backup.sh -H <server-ip> -U postgres -W <password> -t dump -d <database-name>
```

Example:
```bash
bash backup.sh -H 10.0.0.5 -U postgres -W mysecretpass -t dump -d myapp
```

This creates a file like `./backups/dump_myapp_20260313_143055.dump`.

#### Option C: Dump all databases

```bash
bash backup.sh -H <server-ip> -U postgres -W <password> -t dumpall
```

Example:
```bash
bash backup.sh -H 10.0.0.5 -U postgres -W mysecretpass -t dumpall
```

This creates a file like `./backups/dumpall_20260313_143120.sql.gz`.

#### Option D: Interactive mode (prompts for everything)

```bash
bash backup.sh
```

Just run with no arguments — it will ask for host, port, user, password, and backup type.

### Step 5: Verify your backup

```bash
# List all backups
bash restore.sh --list

# Check backup file size
ls -lh ./backups/
```

### Step 6: Restore (when needed)

#### Restore a database dump:
```bash
bash restore.sh -f ./backups/dump_myapp_20260313.dump \
    -H <target-server> -U postgres -W <password> -d myapp
```

#### Restore all databases:
```bash
bash restore.sh -f ./backups/dumpall_20260313.sql.gz \
    -H <target-server> -U postgres -W <password>
```

#### Extract a physical backup (to copy to a server manually):
```bash
bash restore.sh -f ./backups/basebackup_20260313 --restore-dir /tmp/pg_restored
```

Then on the PostgreSQL server:
```bash
sudo systemctl stop postgresql
sudo mv /var/lib/postgresql/16/main /var/lib/postgresql/16/main.old
sudo cp -a /tmp/pg_restored /var/lib/postgresql/16/main
sudo chown -R postgres:postgres /var/lib/postgresql/16/main
sudo systemctl start postgresql
```

#### Interactive mode:
```bash
bash restore.sh
```

---

## Backup Types Explained

| Type | Flag | What It Does | Best For |
|---|---|---|---|
| **basebackup** | `-t basebackup` | Full binary copy of entire PostgreSQL cluster | Disaster recovery, full restore |
| **dump** | `-t dump -d mydb` | Logical SQL dump of one database | Single database backup, migration |
| **dumpall** | `-t dumpall` | Logical dump of ALL databases + users/roles | Full logical backup |

**Which one should you use?**
- Want to back up **one specific database**? Use `dump`
- Want to back up **all databases + users**? Use `dumpall`
- Want a **full binary copy** for disaster recovery? Use `basebackup`

---

## All Options

### backup.sh

```
  -H, --host <host>       PostgreSQL server hostname or IP
  -U, --user <user>       PostgreSQL user (default: postgres)
  -W, --password <pass>   PostgreSQL password
  -p, --port <port>       PostgreSQL port (default: 5432)
  -t, --type <type>       basebackup, dump, dumpall (default: basebackup)
  -d, --database <db>     Database name (required for dump)
  -o, --output <dir>      Output directory (default: ./backups)
  -c, --compress <type>   gzip, lz4, none (default: gzip)
  -j, --jobs <n>          Parallel workers (default: 4)
  --max-rate <rate>       Max transfer rate (e.g. 100M)
```

### restore.sh

```
  -f, --file <path>       Backup file/directory to restore
  -H, --host <host>       PostgreSQL server hostname or IP
  -U, --user <user>       PostgreSQL user (default: postgres)
  -W, --password <pass>   PostgreSQL password
  -p, --port <port>       PostgreSQL port (default: 5432)
  -d, --database <db>     Target database (for dump restore)
  -o, --output <dir>      Backup directory to scan (default: ./backups)
  --restore-dir <dir>     Extract basebackup to this directory
  --list                  List available backups
  -j, --jobs <n>          Parallel workers for pg_restore (default: 4)
```

---

## Automate with Cron

```bash
# Weekly full physical backup (Sunday 2 AM)
0 2 * * 0  /opt/backuppostgres/backup.sh -H db.example.com -U postgres -W "$PG_PASS" -o /backups >> /var/log/pgbackup.log 2>&1

# Daily database dump (Mon-Sat 2 AM)
0 2 * * 1-6  /opt/backuppostgres/backup.sh -H db.example.com -U postgres -W "$PG_PASS" -t dump -d myapp -o /backups >> /var/log/pgbackup.log 2>&1
```

---

## Testing

Run the full test suite (requires Docker):

```bash
bash test.sh
```

Tests all 3 backup types, dump restore with data validation (row counts + checksums), and basebackup extraction.

---

## Troubleshooting

**"connection refused"** — PostgreSQL is not listening on the network. Check `postgresql.conf`:
```
listen_addresses = '*'
```

**"no pg_hba.conf entry"** — Your IP is not allowed. Add it to `pg_hba.conf` (see Step 3).

**"no pg_hba.conf entry for replication"** — You need the `replication` line in `pg_hba.conf` for `basebackup` type.

**"password authentication failed"** — Wrong username or password. Verify with:
```bash
psql -h <server-ip> -U postgres -d postgres -c "SELECT 1;"
```

---

## Files

```
backuppostgres/
├── backup.sh       # Take backups (basebackup / dump / dumpall)
├── restore.sh      # Restore from backups
└── test.sh         # End-to-end test suite (Docker)
```

## License

MIT
