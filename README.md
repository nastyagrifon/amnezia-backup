# Amnezia Backup Tool

Backs up and restores your Amnezia VPN containers.

## What it does

- Creates backup of users with date/time stamps
- Can restore from backups when needed

## How to use

### Make a backup
```bash
./amnezia-backup.sh [backup_dir]
```
If `backup_dir` is not provided, the current working directory is used.

### Restore from backup  
```bash
./amnezia-backup.sh -r [backup_dir]
```

## Configuration

You can override the default settings using environment variables:

- `CONTAINER_PREFIX`: Prefix of containers to backup (default: `amnezia`)
- `RETENTION_COUNT`: Number of old backups to keep (default: `5`)
- `ROLLBACK_RETENTION_COUNT`: Number of safety "pre-restore" backups to keep (default: `2`)
- `CONSISTENT_BACKUP`: If `true`, pauses the container during backup (default: `false`)

Example:
```bash
CONSISTENT_BACKUP=true ./amnezia-backup.sh /path/to/backups
```

## What you need

- Docker running on your system
- This script file
- Enough disk space for backups

## Features

- **Atomic Backups**: Backups are written to temporary files and moved only when complete.
- **Secure Permissions**: Backup files are created with restricted permissions (600).
- **Cleanup**: Automatic cleanup of temporary files on script exit/interruption.
- **Retention**: Automatically keeps only the most recent backups and safety snapshots.
- **Dependency & Resource Checks**: Verifies `docker`, `tar`, and disk space availability.
- **Consistent Backups**: Added option to pause containers during backup for better data integrity.
- **Restore Safety**: Automatically creates a "pre-restore" safety backup before modifying container files. If restore fails, your data remains safe.

## Important

- Restoring will restart your containers
- Test restores carefully 
- Keep your backups safe

## License

Free to use under GPL v3.0 license.
