# backuppostgres

Simple PostgreSQL backup & restore scripts. Uses standard PostgreSQL tools (`pg_basebackup`, `pg_dump`, `pg_restore`) — no extra software needed on the server.

```
┌──────────────────────────┐     PostgreSQL     ┌──────────────────────────┐
│  ANY Linux/Mac host      │     protocol       │  PostgreSQL Server       │
│                          │ ──────────────────> │                          │
│  bash backup.sh          │     (port 5432)     │  Nothing to install.     │
│  bash restore.sh         │ <────────────────── │  Just PostgreSQL.        │
└──────────────────────────┘                     └──────────────────────────┘
```

**No SSH. No pgBackRest. No packages to install on the server. Just `psql`, `pg_basebackup`, `pg_dump`.**

## Quick Start

### Backup

```bash
# Full physical backup (entire cluster)
bash backup.sh -H 10.0.0.5 -U postgres -W mypassword

# SQL dump of a single database
bash backup.sh -H 10.0.0.5 -U postgres -W mypassword -t dump -d myapp

# Dump all databases
bash backup.sh -H 10.0.0.5 -U postgres -W mypassword -t dumpall

# Interactive mode (prompts for everything)
bash backup.sh
```

### Restore

```bash
# List available backups
bash restore.sh --list

# Restore a database dump
bash restore.sh -f ./backups/dump_myapp_20260313.dump -H 10.0.0.5 -U postgres -W mypassword -d myapp

# Extract a physical backup
bash restore.sh -f ./backups/basebackup_20260313 --restore-dir /tmp/pg_restored

# Interactive mode
bash restore.sh
```

## Backup Types

| Type | Command | What It Does | Use Case |
|---|---|---|---|
| **basebackup** | `-t basebackup` | Full physical copy of entire cluster | Disaster recovery, PITR |
| **dump** | `-t dump -d mydb` | Logical SQL dump of one database | Single DB backup, migration |
| **dumpall** | `-t dumpall` | Logical dump of all databases + roles | Full logical backup |

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

## Prerequisites

On the machine running the scripts, you need PostgreSQL client tools:

```bash
# Ubuntu/Debian
sudo apt-get install postgresql-client

# RHEL/CentOS
sudo yum install postgresql

# macOS
brew install postgresql
```

The PostgreSQL **server** needs nothing extra — just standard PostgreSQL.

For `basebackup`, the server's `pg_hba.conf` must allow replication connections:
```
host  replication  all  <your-ip>/32  md5
```

## Cron Schedule Example

```bash
# Weekly full physical backup (Sunday 2 AM)
0 2 * * 0  /opt/backuppostgres/backup.sh -H db.example.com -U postgres -W "$PG_PASS" -o /backups >> /var/log/pgbackup.log 2>&1

# Daily database dump (Mon-Sat 2 AM)
0 2 * * 1-6  /opt/backuppostgres/backup.sh -H db.example.com -U postgres -W "$PG_PASS" -t dump -d myapp -o /backups >> /var/log/pgbackup.log 2>&1
```

## Testing

Run the full test suite (requires Docker):

```bash
bash test.sh
```

Tests all 3 backup types + dump restore with data validation + basebackup extraction.

## Files

```
backuppostgres/
├── backup.sh       # Take backups (basebackup / dump / dumpall)
├── restore.sh      # Restore from backups
└── test.sh         # End-to-end test suite (Docker)
```

## License

MIT
