# backuppostgres

Production-grade PostgreSQL backup & restore using **pgBackRest** over SSH. Run from any backup host — scripts SSH into your remote PostgreSQL server, install pgBackRest, and manage full/differential/incremental backups with point-in-time recovery.

```
┌──────────────┐         SSH          ┌──────────────────────┐
│  Backup Host │ ──────────────────>  │  PostgreSQL Server   │
│  (you run    │                      │  - pgBackRest        │
│   scripts    │  backup.sh full      │  - WAL archiving     │
│   here)      │ <────────────────── │  - Backups stored     │
└──────────────┘       results        └──────────────────────┘
```

## Quick Start

### 1. One-Time Setup

```bash
bash setup.sh
```

Interactive prompts will ask for:
- SSH connection (hostname, user, port)
- PostgreSQL settings (port, superuser, PGDATA path)
- Backup location on remote server (default: `/var/lib/pgbackrest`)
- Compression (lz4, zstd, gzip, none)
- Retention policy

The setup script will:
1. SSH to the remote server
2. Install pgBackRest
3. Configure WAL archiving in PostgreSQL
4. Create and verify the pgBackRest stanza
5. Save config locally (`.pgbackup.conf`) for backup/restore scripts

### 2. Take Backups

```bash
bash backup.sh full          # Full backup (weekly)
bash backup.sh diff          # Differential — changes since last full (daily)
bash backup.sh incr          # Incremental — changes since last backup (hourly)
```

### 3. Monitor

```bash
bash backup.sh info          # View backup details
bash backup.sh verify        # Verify backup integrity
bash backup.sh storage       # Show disk usage on remote server
```

### 4. Restore

```bash
bash restore.sh                              # Interactive — list and choose
bash restore.sh --latest                     # Restore latest backup
bash restore.sh --set 20260309-075435F       # Restore specific backup set
bash restore.sh --pitr '2026-03-09 08:00:00' # Point-in-time recovery
bash restore.sh --info                       # List available backups
bash restore.sh --verify                     # Verify integrity
```

## Backup Location Options

**Default:** backups stored on the remote PG server (path chosen during setup).

**Custom remote path:**
```bash
bash backup.sh full --backup-dir /mnt/nfs/pgbackups
```

**Download to local machine after backup:**
```bash
bash backup.sh full --pull /local/backups
```

## All Options

### backup.sh

```
COMMANDS
  full                    Full backup
  diff                    Differential backup (changes since last full)
  incr                    Incremental backup (changes since last backup)
  info                    Show backup information
  verify                  Verify backup integrity
  storage                 Show backup disk usage

OPTIONS
  --backup-dir <dir>      Override backup directory on remote server
  --pull <local-dir>      Download backup repo to local machine after backup
  --stanza <name>         Override stanza name
  --process-max <n>       Override parallel workers
  --dry-run               Show what would be done without executing
```

### restore.sh

```
  --latest                Restore the latest backup
  --set <label>           Restore a specific backup set
  --pitr <timestamp>      Point-in-time recovery (e.g. '2026-03-09 14:30:00+00')
  --info                  List available backups
  --verify                Verify backup integrity
  --no-delta              Full restore (skip delta optimization)
  --stanza <name>         Override stanza name
```

## Backup Types

| Type | What It Backs Up | Size | Restore Speed | Use Case |
|---|---|---|---|---|
| **Full** | Everything | Largest | Fastest | Weekly baseline |
| **Differential** | Changes since last full | Medium | Fast (full + 1 diff) | Daily |
| **Incremental** | Changes since last backup | Smallest | Slower (full + chain) | Hourly |

## Recommended Schedule

```
┌─────────┬──────────┬──────────┬──────────┬──────────┬──────────┬──────────┬──────────┐
│         │  Monday  │ Tuesday  │Wednesday │ Thursday │  Friday  │ Saturday │  Sunday  │
├─────────┼──────────┼──────────┼──────────┼──────────┼──────────┼──────────┼──────────┤
│  2 AM   │   DIFF   │   DIFF   │   DIFF   │   DIFF   │   DIFF   │   DIFF   │  FULL    │
│ Hourly  │   INCR   │   INCR   │   INCR   │   INCR   │   INCR   │   INCR   │   INCR   │
└─────────┴──────────┴──────────┴──────────┴──────────┴──────────┴──────────┴──────────┘
```

### Cron Example

```bash
# Weekly full backup (Sunday 2 AM)
0 2 * * 0  /opt/backuppostgres/backup.sh full  >> /var/log/pgbackup.log 2>&1

# Daily differential (Mon-Sat 2 AM)
0 2 * * 1-6  /opt/backuppostgres/backup.sh diff >> /var/log/pgbackup.log 2>&1

# Hourly incremental
0 * * * *  /opt/backuppostgres/backup.sh incr >> /var/log/pgbackup.log 2>&1
```

## Prerequisites

- SSH access to the PostgreSQL server (key-based auth recommended)
- The SSH user must have `sudo` privileges
- PostgreSQL superuser access on the remote server

## Files

```
backuppostgres/
├── setup.sh        # One-time: install pgBackRest + configure WAL archiving
├── backup.sh       # Take full/diff/incr backups via SSH
└── restore.sh      # Restore via SSH (latest, specific set, PITR)
```

## License

MIT
