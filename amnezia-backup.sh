#!/bin/bash

# --- Default Configuration ---
RESTORE_MODE=false
DRY_RUN=false
VERBOSE=false
PROVIDED_DIR=""
CONTAINER_PREFIX="${CONTAINER_PREFIX:-amnezia}"
DATE_SUFFIX=$(date +%Y%m%d_%H%M%S)
RETENTION_COUNT="${RETENTION_COUNT:-5}"
ROLLBACK_RETENTION_COUNT="${ROLLBACK_RETENTION_COUNT:-2}"
CONSISTENT_BACKUP="${CONSISTENT_BACKUP:-false}"

# --- Helper Functions ---

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [BACKUP_DIR]

Backs up or restores /opt/ directories of Amnezia VPN containers.

Options:
  -r           Restore mode (default is backup mode)
  -n           Dry run: show what would happen without making changes
  -v           Verbose mode: show more detailed output
  -h, --help   Show this help message

Arguments:
  BACKUP_DIR   Directory to store/read backups (default: current directory)

Environment Variables:
  CONTAINER_PREFIX           Prefix of containers to target (default: amnezia)
  RETENTION_COUNT            Number of regular backups to keep (default: 5)
  ROLLBACK_RETENTION_COUNT   Number of safety backups to keep (default: 2)
  CONSISTENT_BACKUP          Set to "true" to pause container during backup

Examples:
  $(basename "$0") /mnt/backups
  $(basename "$0") -r /mnt/backups
  CONSISTENT_BACKUP=true $(basename "$0") -v
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r) RESTORE_MODE=true; shift ;;
        -n) DRY_RUN=true; shift ;;
        -v) VERBOSE=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        -*) echo "Unknown option: $1"; show_help; exit 1 ;;
        *) PROVIDED_DIR="$1"; shift ;;
    esac
done

# Resolve Backup Directory
if [[ -n "$PROVIDED_DIR" ]]; then
    mkdir -p "$PROVIDED_DIR" || { echo "ERROR: Could not create directory $PROVIDED_DIR"; exit 1; }
    BACKUP_DIR="$(cd "$PROVIDED_DIR" && pwd)"
else
    BACKUP_DIR="$(pwd)"
fi

# --- BLACKLIST: Containers to be excluded from backup and restore ---
# Only 'amnezia-dns' is blacklisted as per request.
BLACKLIST=("amnezia-dns")

# Track failures for exit code
FAILURES=0

# --- Helper Functions ---

log_v() {
    [[ "$VERBOSE" == "true" ]] && echo "  [DEBUG] $*"
}

# Get container state (running, paused, exited, etc.)
get_container_state() {
    docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null
}

# Check dependencies
check_dependencies() {
    log_v "Checking dependencies..."
    for cmd in docker tar awk df; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "ERROR: Required command '$cmd' not found. Please install it."
            exit 1
        fi
    done
    if ! docker info &> /dev/null; then
        echo "ERROR: Cannot connect to Docker daemon. Check permissions (sudo?)."
        exit 1
    fi
}

# Check disk space (minimum 100MB)
check_disk_space() {
    local REQUIRED_KB=102400
    mkdir -p "$BACKUP_DIR"
    local AVAILABLE_KB=$(df -Pk "$BACKUP_DIR" | tail -1 | awk '{print $4}')
    if [[ $AVAILABLE_KB -lt $REQUIRED_KB ]]; then
        echo "ERROR: Insufficient disk space in $BACKUP_DIR (less than 100MB available)."
        exit 1
    fi
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

# Robust retention policy
apply_retention() {
    local CONTAINER_NAME="$1"
    
    # Regular backups
    ls -t "$BACKUP_DIR/$CONTAINER_NAME-opt-"*.tar.gz 2>/dev/null | grep -v "pre-restore" | tail -n +$((RETENTION_COUNT + 1)) | while read -r old_file; do
        if [[ -f "$old_file" ]]; then
            echo "  Cleaning up old backup: $(basename "$old_file")"
            rm -f "$old_file"
        fi
    done

    # Pre-restore backups
    ls -t "$BACKUP_DIR/$CONTAINER_NAME-opt-pre-restore-"*.tar.gz 2>/dev/null | tail -n +$((ROLLBACK_RETENTION_COUNT + 1)) | while read -r old_file; do
        if [[ -f "$old_file" ]]; then
            echo "  Cleaning up old safety backup: $(basename "$old_file")"
            rm -f "$old_file"
        fi
    done
}

# Function to perform the actual /opt/ backup for a single container
backup_container_opt() {
    local CONTAINER_NAME="$1"
    local SUFFIX="${2:-$DATE_SUFFIX}"
    local BACKUP_FILE="$BACKUP_DIR/$CONTAINER_NAME-opt-$SUFFIX.tar.gz"
    local TMP_BACKUP_FILE="$BACKUP_FILE.tmp"
    local PAUSED=false
    
    echo "--- Starting /opt/ backup for $CONTAINER_NAME ---"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY RUN] Would backup $CONTAINER_NAME to $BACKUP_FILE"
        return 0
    fi

    # Check disk space before starting each backup
    check_disk_space

    # 1. Handle consistency if requested
    if [[ "$CONSISTENT_BACKUP" == "true" ]]; then
        local CURRENT_STATE=$(get_container_state "$CONTAINER_NAME")
        if [[ "$CURRENT_STATE" == "running" ]]; then
            echo "  Pausing container for consistency..."
            if docker pause "$CONTAINER_NAME" &>/dev/null; then
                PAUSED=true
            else
                echo "  WARNING: Failed to pause $CONTAINER_NAME. Proceeding with live backup."
            fi
        else
            log_v "Container $CONTAINER_NAME is in state '$CURRENT_STATE', skipping pause."
        fi
    fi

    # 2. Create temporary directory for extraction
    local CONTAINER_TEMP_DIR="$SCRIPT_TEMP_DIR/${CONTAINER_NAME}_$SUFFIX"
    mkdir -p "$CONTAINER_TEMP_DIR"
    
    # 3. Copy /opt/ out of the container
    echo "  Copying /opt/ from container..."
    log_v "Running: docker cp $CONTAINER_NAME:/opt/ $CONTAINER_TEMP_DIR/${CONTAINER_NAME}_opt"
    if ! docker cp "$CONTAINER_NAME":/opt/ "$CONTAINER_TEMP_DIR/${CONTAINER_NAME}_opt"; then
        echo "  ERROR: Failed to copy /opt/ using docker cp. Skipping."
        [[ "$PAUSED" == "true" ]] && docker unpause "$CONTAINER_NAME" &>/dev/null
        ((FAILURES++))
        return 1
    fi

    # 4. Unpause as soon as copy is done
    if [[ "$PAUSED" == "true" ]]; then
        echo "  Unpausing container..."
        docker unpause "$CONTAINER_NAME" &>/dev/null
    fi

    # 5. Compress the copied /opt/ directory into a single tar.gz
    echo "  Compressing into $BACKUP_FILE..."
    log_v "Running: tar czf $TMP_BACKUP_FILE -C $CONTAINER_TEMP_DIR ${CONTAINER_NAME}_opt"
    if ! tar czf "$TMP_BACKUP_FILE" -C "$CONTAINER_TEMP_DIR" "${CONTAINER_NAME}_opt"; then
        echo "  ERROR: Failed to create tar.gz archive. Skipping."
        rm -f "$TMP_BACKUP_FILE"
        ((FAILURES++))
        return 1
    fi

    # 4. Finalize backup (Atomic move and secure permissions)
    log_v "Finalizing backup file..."
    mv "$TMP_BACKUP_FILE" "$BACKUP_FILE"
    chmod 600 "$BACKUP_FILE"
    
    # 5. Clean up container-specific temp dir
    rm -rf "$CONTAINER_TEMP_DIR"

    # 6. Apply retention policy
    apply_retention "$CONTAINER_NAME"

    echo "  SUCCESS: Backup saved to $BACKUP_FILE"
    echo "--------------------------------------------------------"
    return 0
}

# Function to restore /opt/ directory of a single container
restore_container_opt() {
    local CONTAINER_NAME="$1"
    
    # Robust file selection: find latest regular backup (exclude pre-restore)
    local LATEST_BACKUP=$(ls -t "$BACKUP_DIR/$CONTAINER_NAME"-opt-*.tar.gz 2>/dev/null | grep -v "pre-restore" | head -n 1)

    if [[ -z "$LATEST_BACKUP" ]]; then
        echo "ERROR: No /opt/ backup found for $CONTAINER_NAME in $BACKUP_DIR. Skipping restore."
        ((FAILURES++))
        return 1
    fi

    echo "--- Starting in-place /opt/ restore for $CONTAINER_NAME from $(basename "$LATEST_BACKUP") ---"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY RUN] Would restore $CONTAINER_NAME from $LATEST_BACKUP"
        return 0
    fi

    # Record initial state
    local INITIAL_STATE=$(get_container_state "$CONTAINER_NAME")
    log_v "Initial state of $CONTAINER_NAME: $INITIAL_STATE"

    # 1. Create Safety Backup before modification
    local ROLLBACK_SUFFIX="pre-restore-$DATE_SUFFIX"
    local ROLLBACK_FILE="$BACKUP_DIR/$CONTAINER_NAME-opt-$ROLLBACK_SUFFIX.tar.gz"
    echo "  Creating safety backup..."
    if ! backup_container_opt "$CONTAINER_NAME" "$ROLLBACK_SUFFIX" &>/dev/null; then
        echo "  ERROR: Failed to create safety backup. Aborting restore to prevent data loss."
        ((FAILURES++))
        return 1
    fi

    # TODO: Implement clean restores. Currently, 'docker cp' merges files.
    # A clean restore would involve:
    # 1. docker run --rm -v container_opt:/target alpine sh -c "rm -rf /target/*"
    # (requires identifying the correct volume or mount point)

    local CONTAINER_TEMP_DIR="$SCRIPT_TEMP_DIR/restore_${CONTAINER_NAME}_$DATE_SUFFIX"
    mkdir -p "$CONTAINER_TEMP_DIR"
    
    # 2. Stop container if it's running/paused
    if [[ "$INITIAL_STATE" == "running" || "$INITIAL_STATE" == "paused" ]]; then
        echo "  Stopping container..."
        if ! docker stop "$CONTAINER_NAME"; then
            echo "  ERROR: Failed to stop $CONTAINER_NAME. Aborting restore."
            ((FAILURES++))
            return 1
        fi
    else
        log_v "Container is not running ($INITIAL_STATE), skipping stop."
    fi
    
    # 3. Unpack and copy
    echo "  Unpacking archive..."
    if ! tar xzf "$LATEST_BACKUP" -C "$CONTAINER_TEMP_DIR"; then
        echo "  ERROR: Failed to unpack backup. Aborting."
        echo "  ROLLBACK INFO: Your data is safe in $ROLLBACK_FILE"
        [[ "$INITIAL_STATE" == "running" ]] && docker start "$CONTAINER_NAME" 2>/dev/null
        ((FAILURES++))
        return 1
    fi
    
    echo "  Copying /opt/ content back into container..."
    log_v "Running: docker cp $CONTAINER_TEMP_DIR/${CONTAINER_NAME}_opt/. $CONTAINER_NAME:/opt/"
    if docker cp "$CONTAINER_TEMP_DIR/${CONTAINER_NAME}_opt/." "$CONTAINER_NAME:/opt/"; then
        echo "  SUCCESS: /opt/ content updated."
    else
        echo "  ERROR: docker cp failed. Manual check required."
        echo "  ROLLBACK REQUIRED: Use $ROLLBACK_FILE to restore manually."
        ((FAILURES++))
    fi
    
    # Clean up container-specific temp dir
    rm -rf "$CONTAINER_TEMP_DIR"
    
    # 4. Restore initial state
    if [[ "$INITIAL_STATE" == "running" ]]; then
        echo "  Starting container..."
        if ! docker start "$CONTAINER_NAME"; then
            echo "  WARNING: Failed to start $CONTAINER_NAME. Manual check required."
            ((FAILURES++))
            return 1
        fi
    else
        log_v "Preserving initial state ($INITIAL_STATE), not starting container."
    fi
    
    echo "SUCCESS: Container restored."
    echo "  Note: Safety backup kept at $ROLLBACK_FILE"
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
if [[ "$RESTORE_MODE" == "true" ]]; then
    # RESTORE MODE
    echo "--- Amnezia Docker Restore Mode (Simplified /opt/ Restore) ---"
    echo "Backup Directory: $BACKUP_DIR"
    [[ "$DRY_RUN" == "true" ]] && echo "[DRY RUN ENABLED] No changes will be made."
    echo "Containers to restore (excluding: ${BLACKLIST[*]}):"
    printf " - %s\n" "${FILTERED_NAMES_ARRAY[@]}"
    echo "--------------------------------------------------------"
    
    for NAME in "${FILTERED_NAMES_ARRAY[@]}"; do
        restore_container_opt "$NAME"
    done
else
    # BACKUP MODE (Default)
    echo "--- Amnezia Docker Backup Mode (Simplified /opt/ Backup) ---"
    echo "Backup Directory: $BACKUP_DIR"
    [[ "$DRY_RUN" == "true" ]] && echo "[DRY RUN ENABLED] No changes will be made."
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
