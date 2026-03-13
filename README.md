# backuppostgres

Production-grade PostgreSQL backup & restore using **pgBackRest** with a **dedicated backup host** architecture. Backups are stored safely on a separate machine — not on the production database server.

```
┌──────────────────────────┐              ┌──────────────────────────┐
│  BACKUP HOST (this box)  │     SSH      │  POSTGRESQL SERVER       │
│                          │ ──────────>  │                          │
│  - pgBackRest installed  │  streams     │  - PostgreSQL            │
│  - Backups stored HERE   │  data back   │  - Thin pgBackRest agent │
│  - You run scripts HERE  │ <──────────  │    (WAL archiving only)  │
│                          │              │                          │
└──────────────────────────┘              └──────────────────────────┘
```

## Why This Architecture?

- **No risk to production** — backup software and storage are on a separate machine
- **Backups survive DB server failure** — stored on the backup host, not the DB server
- **Minimal footprint on PG server** — only a thin agent for WAL shipping
- **Network isolation** — backup host can be in a different network/DC

## Quick Start

### 1. One-Time Setup

```bash
bash setup.sh
```

Interactive prompts will ask for:
- SSH connection to PostgreSQL server (hostname, user, port)
- PostgreSQL settings (port, superuser, PGDATA path)
- Local backup directory on this machine (default: `/var/lib/pgbackrest`)
- Compression (lz4, zstd, gzip)
- Retention policy

The setup script will:
1. Install pgBackRest on **this backup host**
2. Install thin pgBackRest agent on the **PG server** (via SSH)
3. Set up SSH keys for bidirectional access (backup ↔ PG server)
4. Configure `pgbackrest.conf` on both hosts
5. Configure WAL archiving on the PG server (pushes WALs to this host)
6. Create and verify the pgBackRest stanza

### 2. Take Backups

```bash
bash backup.sh full          # Full backup (weekly)
bash backup.sh diff          # Differential — changes since last full (daily)
bash backup.sh incr          # Incremental — changes since last backup (hourly)
```

All backups run **locally** on this machine. pgBackRest automatically SSHes to the PG server to stream data back.

### 3. Monitor

```bash
bash backup.sh info          # View backup details
bash backup.sh verify        # Verify backup integrity
bash backup.sh storage       # Show local disk usage
```

### 4. Restore

```bash
# Interactive — list backups and choose
bash restore.sh

# Restore latest backup
bash restore.sh --latest

# Restore a specific backup set
bash restore.sh --set 20260309-075435F

# Point-in-time recovery
bash restore.sh --pitr '2026-03-09 14:30:00+00'

# View available backups / verify
bash restore.sh --info
bash restore.sh --verify
```

Restore runs from this backup host, streams data to the PG server via SSH, stops/starts PostgreSQL automatically.

## All Options

### backup.sh

| Command | Description |
|---|---|
| `full` | Full backup |
| `diff` | Differential (changes since last full) |
| `incr` | Incremental (changes since last backup) |
| `info` | Show backup information |
| `verify` | Verify backup integrity |
| `storage` | Show backup disk usage |

| Option | Description |
|---|---|
| `--stanza <name>` | Override stanza name |
| `--process-max <n>` | Override parallel workers |
| `--dry-run` | Show command without executing |

### restore.sh

| Option | Description |
|---|---|
| `--latest` | Restore the latest backup |
| `--set <label>` | Restore a specific backup set |
| `--pitr <timestamp>` | Point-in-time recovery |
| `--info` | List available backups |
| `--verify` | Verify backup integrity |
| `--no-delta` | Full restore (skip delta optimization) |
| `--stanza <name>` | Override stanza name |

## Recommended Cron Schedule

```bash
# Weekly full backup (Sunday 2 AM)
0 2 * * 0  /opt/backuppostgres/backup.sh full  >> /var/log/pgbackup.log 2>&1

# Daily differential (Mon-Sat 2 AM)
0 2 * * 1-6  /opt/backuppostgres/backup.sh diff >> /var/log/pgbackup.log 2>&1

# Hourly incremental
0 * * * *  /opt/backuppostgres/backup.sh incr >> /var/log/pgbackup.log 2>&1
```

## Prerequisites

- A dedicated backup host (separate machine from the PG server)
- SSH access from backup host to PG server (key-based auth, set up automatically)
- The SSH user on PG server must have `sudo` privileges
- PostgreSQL superuser access on the remote server

## Files

```
backuppostgres/
├── setup.sh        # One-time: install pgBackRest on both hosts, configure SSH + WAL
├── backup.sh       # Take full/diff/incr backups (runs locally, streams from PG)
└── restore.sh      # Restore (runs locally, streams to PG server)
```

## License

MIT
