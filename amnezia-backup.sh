#!/bin/bash

# Configuration
BACKUP_DIR="${BACKUP_DIR:-./amnezia_opt_backups}"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-amnezia}"
DATE_SUFFIX=$(date +%Y%m%d_%H%M%S)
RETENTION_COUNT="${RETENTION_COUNT:-5}"

# --- BLACKLIST: Containers to be excluded from backup and restore ---
# Only 'amnezia-dns' is blacklisted as per request.
BLACKLIST=("amnezia-dns")

# Track failures for exit code
FAILURES=0

# --- Helper Functions ---

# Check dependencies
check_dependencies() {
    for cmd in docker tar; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "ERROR: Required command '$cmd' not found. Please install it."
            exit 1
        fi
    done
}

# Cleanup on exit
cleanup() {
    if [[ -n "$SCRIPT_TEMP_DIR" && -d "$SCRIPT_TEMP_DIR" ]]; then
        rm -rf "$SCRIPT_TEMP_DIR"
    fi
}
trap cleanup EXIT

# Initialize script-wide temp dir
SCRIPT_TEMP_DIR=$(mktemp -d)

# Check dependencies before starting
check_dependencies

# Check if a container name is in the blacklist
is_blacklisted() {
    local NAME="$1"
    for item in "${BLACKLIST[@]}"; do
        if [[ "$NAME" == "$item" ]]; then
            return 0 # True (is blacklisted)
        fi
    done
    return 1 # False (not blacklisted)
}

# Function to perform the actual /opt/ backup for a single container
backup_container_opt() {
    local CONTAINER_NAME="$1"
    local BACKUP_FILE="$BACKUP_DIR/$CONTAINER_NAME-opt-$DATE_SUFFIX.tar.gz"
    local TMP_BACKUP_FILE="$BACKUP_FILE.tmp"
    
    echo "--- Starting /opt/ backup for $CONTAINER_NAME ---"
    
    # TODO: Implement consistent backups by pausing/stopping the container
    # during the copy if data integrity is critical.

    # 1. Create temporary directory for extraction
    local CONTAINER_TEMP_DIR="$SCRIPT_TEMP_DIR/${CONTAINER_NAME}_$DATE_SUFFIX"
    mkdir -p "$CONTAINER_TEMP_DIR"
    
    # 2. Copy /opt/ out of the container
    echo "  Copying /opt/ from container..."
    if ! docker cp "$CONTAINER_NAME":/opt/ "$CONTAINER_TEMP_DIR/${CONTAINER_NAME}_opt"; then
        echo "  ERROR: Failed to copy /opt/ using docker cp. Skipping."
        ((FAILURES++))
        return 1
    fi

    # 3. Compress the copied /opt/ directory into a single tar.gz
    echo "  Compressing into $BACKUP_FILE..."
    if ! tar czf "$TMP_BACKUP_FILE" -C "$CONTAINER_TEMP_DIR" "${CONTAINER_NAME}_opt"; then
        echo "  ERROR: Failed to create tar.gz archive. Skipping."
        rm -f "$TMP_BACKUP_FILE"
        ((FAILURES++))
        return 1
    fi

    # 4. Finalize backup (Atomic move and secure permissions)
    mv "$TMP_BACKUP_FILE" "$BACKUP_FILE"
    chmod 600 "$BACKUP_FILE"
    
    # 5. Clean up container-specific temp dir
    rm -rf "$CONTAINER_TEMP_DIR"

    # 6. Apply retention policy
    local BACKUP_PATTERN="$BACKUP_DIR/$CONTAINER_NAME-opt-*.tar.gz"
    local OLD_BACKUPS=$(ls -t $BACKUP_PATTERN 2>/dev/null | tail -n +$((RETENTION_COUNT + 1)))
    if [[ -n "$OLD_BACKUPS" ]]; then
        echo "  Cleaning up old backups (keeping last $RETENTION_COUNT)..."
        rm -f $OLD_BACKUPS
    fi

    echo "  SUCCESS: Backup saved to $BACKUP_FILE"
    echo "--------------------------------------------------------"
    return 0
}

# Function to restore /opt/ directory of a single container
restore_container_opt() {
    local CONTAINER_NAME="$1"
    
    local LATEST_BACKUP=$(ls -t "$BACKUP_DIR/$CONTAINER_NAME"-opt-*.tar.gz 2>/dev/null | head -n 1)

    if [[ -z "$LATEST_BACKUP" ]]; then
        echo "ERROR: No /opt/ backup found for $CONTAINER_NAME in $BACKUP_DIR. Skipping restore."
        ((FAILURES++))
        return 1
    fi

    echo "--- Starting in-place /opt/ restore for $CONTAINER_NAME from $(basename "$LATEST_BACKUP") ---"
    
    # TODO: Implement clean restores by wiping /opt/ in the container first.
    # TODO: Implement rollback if restore fails.

    local CONTAINER_TEMP_DIR="$SCRIPT_TEMP_DIR/restore_${CONTAINER_NAME}_$DATE_SUFFIX"
    mkdir -p "$CONTAINER_TEMP_DIR"
    
    echo "  Stopping container..."
    if ! docker stop "$CONTAINER_NAME"; then
        echo "  ERROR: Failed to stop $CONTAINER_NAME. Aborting restore."
        ((FAILURES++))
        return 1
    fi
    
    echo "  Unpacking archive..."
    if ! tar xzf "$LATEST_BACKUP" -C "$CONTAINER_TEMP_DIR"; then
        echo "  ERROR: Failed to unpack backup. Aborting."
        docker start "$CONTAINER_NAME" 2>/dev/null
        ((FAILURES++))
        return 1
    fi
    
    echo "  Copying /opt/ content back into container..."
    if docker cp "$CONTAINER_TEMP_DIR/${CONTAINER_NAME}_opt/." "$CONTAINER_NAME:/opt/"; then
        echo "  SUCCESS: /opt/ content updated."
    else
        echo "  ERROR: docker cp failed. Manual check required."
        ((FAILURES++))
    fi
    
    # Clean up container-specific temp dir
    rm -rf "$CONTAINER_TEMP_DIR"
    
    echo "  Starting container..."
    if ! docker start "$CONTAINER_NAME"; then
        echo "  WARNING: Failed to start $CONTAINER_NAME. Manual check required."
        ((FAILURES++))
        return 1
    fi
    
    echo "SUCCESS: Container restored and restarted."
    echo "--------------------------------------------------------"
    return 0
}

# --- Main Execution Logic ---

# 1. Get ALL container names, filter by prefix, and save as a Bash array.
# The 'tr' command is used to replace spaces with newlines, ensuring each name is on a separate line.
readarray -t ALL_CONTAINER_NAMES < <(docker ps -a --format '{{.Names}}' | grep "^$CONTAINER_PREFIX")

# 2. Filter the array against the blacklist.
FILTERED_NAMES_ARRAY=()
for NAME in "${ALL_CONTAINER_NAMES[@]}"; do
    # ROBUSTNESS: Ensure the name is not empty and not blacklisted.
    if [[ -n "$NAME" ]] && ! is_blacklisted "$NAME"; then
        FILTERED_NAMES_ARRAY+=("$NAME")
    fi
done

if [[ ${#FILTERED_NAMES_ARRAY[@]} -eq 0 ]]; then
    echo "INFO: No containers starting with '$CONTAINER_PREFIX' found or all are blacklisted."
    exit 0
fi

# Determine if running in restore or backup mode
if [[ "$1" == "-r" ]]; then
    # RESTORE MODE
    echo "--- Amnezia Docker Restore Mode (Simplified /opt/ Restore) ---"
    echo "Containers to restore (excluding: ${BLACKLIST[*]}):"
    printf " - %s\n" "${FILTERED_NAMES_ARRAY[@]}"
    echo "--------------------------------------------------------"
    
    for NAME in "${FILTERED_NAMES_ARRAY[@]}"; do
        restore_container_opt "$NAME"
    done
else
    # BACKUP MODE (Default)
    echo "--- Amnezia Docker Backup Mode (Simplified /opt/ Backup) ---"
    mkdir -p "$BACKUP_DIR"
    echo "Containers to backup (excluding: ${BLACKLIST[*]}):"
    printf " - %s\n" "${FILTERED_NAMES_ARRAY[@]}"
    echo "--------------------------------------------------------"
    
    for NAME in "${FILTERED_NAMES_ARRAY[@]}"; do
        backup_container_opt "$NAME"
    done
fi

if [[ $FAILURES -gt 0 ]]; then
    echo "COMPLETED with $FAILURES error(s)."
    exit 1
fi

echo "COMPLETED SUCCESSFULLY."
exit 0
