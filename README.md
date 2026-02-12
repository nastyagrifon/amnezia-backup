# Amnezia Backup Tool

Backs up and restores your Amnezia VPN containers.

## What it does

- Creates backup of users with date/time stamps
- Can restore from backups when needed

## How to use

### Make a backup
```bash
./amnezia-backup.sh
```

### Restore from backup  
```bash
./amnezia-backup.sh -r
```

## What you need

- Docker running on your system
- This script file
- Enough disk space for backups

## Configuration

You can override the default settings using environment variables:

- `BACKUP_DIR`: Path to save backups (default: `./amnezia_opt_backups`)
- `CONTAINER_PREFIX`: Prefix of containers to backup (default: `amnezia`)
- `RETENTION_COUNT`: Number of old backups to keep (default: `5`)
- `CONSISTENT_BACKUP`: If `true`, pauses the container during backup (default: `false`)

Example:
```bash
CONSISTENT_BACKUP=true ./amnezia-backup.sh
```

## Features

- **Atomic Backups**: Backups are written to temporary files and moved only when complete.
- **Secure Permissions**: Backup files are created with restricted permissions (600).
- **Cleanup**: Automatic cleanup of temporary files on script exit/interruption.
- **Retention**: Automatically keeps only the most recent backups.
- **Dependency Checks**: Verifies `docker` and `tar` are installed.
- **Consistent Backups**: Added option to pause containers during backup for better data integrity.
- **Restore Safety**: Automatically creates a "pre-restore" safety backup before modifying container files. If restore fails, your data remains safe.

## Important

- Restoring will restart your containers
- Test restores carefully 
- Keep your backups safe

## License

Free to use under GPL v3.0 license.
