#!/usr/bin/env bash
# Backup/restore abstraction — delegates to provider for cloud storage ops.
# Sourced by setup.sh.
#
# Expects these globals from the calling context (setup.sh):
#   BACKUP_RETENTION_DAYS — days to retain backups (default: 90)
#   SECRETS_PREFIX        — Secret Manager prefix (default: openclaw)

# Canonical list of data directories to backup/restore.
# SYNC: This list MUST match the copies in:
#   - providers/gcp/infra/startup.sh (sections 6 + 7)
#   - providers/gcp/scripts/restore.sh
# See AGENTS.md "Adding a new backed-up directory" for the full update checklist.
BACKUP_DATA_DIRS="credentials identity agents memory extensions devices cron canvas completions media subagents"

# Browser cache directories to strip during backup/restore (save disk, avoid stale data)
BROWSER_CACHE_STRIP_DIRS=("Cache" "Code Cache" "Service Worker")

# ---------------------------------------------------------------------------
# Backup from VM (runs remotely via SSH)
# This generates the backup script that runs on the VM.
# NOTE: The generated script contains its own copy of BACKUP_DATA_DIRS and
# BROWSER_CACHE_STRIP_DIRS because it runs standalone (not sourced).
# ---------------------------------------------------------------------------
generate_backup_script() {
  local output="$1"
  local bucket="$2"
  local openclaw_repo="$3"

  cat > "$output" << 'BACKUP_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

BUCKET="gs://BUCKET_PLACEHOLDER"
CONTAINER="openclaw-openclaw-gateway-1"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/tmp/openclaw-backup-$TIMESTAMP"
BACKUP_FILE="/tmp/openclaw-backup-$TIMESTAMP.tar.gz"
OPENCLAW_REPO="REPO_PLACEHOLDER"
OPENCLAW_DIR="$HOME/.openclaw"
RETENTION_DAYS=RETENTION_PLACEHOLDER

# Clean up temp files on exit (success or failure)
cleanup_backup() {
  rm -rf "$BACKUP_DIR" "$BACKUP_FILE" "${BACKUP_FILE}.age" 2>/dev/null
}
trap cleanup_backup EXIT

echo "[$(date)] Starting backup..."
mkdir -p "$BACKUP_DIR/workspace"

# Critical: openclaw.json must succeed
if ! docker cp "$CONTAINER:/home/node/.openclaw/openclaw.json" "$BACKUP_DIR/" 2>/dev/null; then
  echo "[WARN] Failed to copy openclaw.json — backup may be incomplete" >&2
fi

# Data directories — SYNC: keep in sync with startup.sh (sections 6+7) and providers/gcp/scripts/restore.sh
for dir in credentials identity agents memory extensions devices cron canvas completions media subagents; do
  docker cp "$CONTAINER:/home/node/.openclaw/$dir" "$BACKUP_DIR/$dir" 2>/dev/null \
    || echo "[WARN] Failed to copy $dir" >&2
done

# Browser data from host (not container) — strip caches
cp -r "$OPENCLAW_DIR/browser" "$BACKUP_DIR/browser" 2>/dev/null || echo "[WARN] No browser data" >&2
rm -rf "$BACKUP_DIR/browser/chrome-data/Default/Cache" 2>/dev/null
rm -rf "$BACKUP_DIR/browser/chrome-data/Default/Code Cache" 2>/dev/null
rm -rf "$BACKUP_DIR/browser/chrome-data/Default/Service Worker" 2>/dev/null

# Workspace files
for f in AGENTS.md SOUL.md USER.md IDENTITY.md TOOLS.md HEARTBEAT.md; do
  docker cp "$CONTAINER:/home/node/.openclaw/workspace/$f" "$BACKUP_DIR/workspace/" 2>/dev/null || true
done
docker cp "$CONTAINER:/home/node/.openclaw/workspace/memory" "$BACKUP_DIR/workspace/memory" 2>/dev/null || true

# Docker config (non-secret .env is a symlink to tmpfs — backup resolves to empty or non-secret values)
cp "$OPENCLAW_REPO/docker-compose.yml" "$BACKUP_DIR/" 2>/dev/null || true
cp "$OPENCLAW_REPO/docker-compose.override.yml" "$BACKUP_DIR/" 2>/dev/null || true

# agent-config.yml if present
cp "$HOME/agent-config.yml" "$BACKUP_DIR/" 2>/dev/null || true

# Create tarball
tar -czf "$BACKUP_FILE" -C /tmp "openclaw-backup-$TIMESTAMP"

# Encrypt backup with age (public key from Secret Manager)
if command -v age &>/dev/null; then
  AGE_PUBLIC_KEY=$(gcloud secrets versions access latest --secret="SECRETS_PREFIX_PLACEHOLDER-age-public-key" 2>/dev/null || echo "")
  if [ -n "$AGE_PUBLIC_KEY" ]; then
    age -r "$AGE_PUBLIC_KEY" -o "$BACKUP_FILE.age" "$BACKUP_FILE"
    rm -f "$BACKUP_FILE"
    BACKUP_FILE="$BACKUP_FILE.age"
    echo "[$(date)] Backup encrypted with age"
  fi
else
  echo "[WARN] age not installed — backup will not be encrypted" >&2
fi

UPLOAD_NAME="openclaw-$TIMESTAMP.tar.gz"
LATEST_NAME="openclaw-latest.tar.gz"
if [[ "$BACKUP_FILE" == *.age ]]; then
  UPLOAD_NAME="openclaw-$TIMESTAMP.tar.gz.age"
  LATEST_NAME="openclaw-latest.tar.gz.age"
fi
gcloud storage cp "$BACKUP_FILE" "$BUCKET/backups/$UPLOAD_NAME" --quiet
gcloud storage cp "$BACKUP_FILE" "$BUCKET/backups/$LATEST_NAME" --quiet
rm -rf "$BACKUP_DIR" "$BACKUP_FILE"

# Retention: delete backups older than configured retention days
CUTOFF_DATE=$(date -d "-${RETENTION_DAYS} days" +%Y%m%d 2>/dev/null || echo "")
if [ -n "$CUTOFF_DATE" ]; then
  gcloud storage ls "$BUCKET/backups/openclaw-2*" 2>/dev/null | while IFS= read -r backup_path; do
    backup_date=$(echo "$backup_path" | grep -oE '[0-9]{8}' | head -1)
    if [ -n "$backup_date" ] && [ "$backup_date" -lt "$CUTOFF_DATE" ] 2>/dev/null; then
      gcloud storage rm "$backup_path" --quiet 2>/dev/null || true
      echo "[$(date)] Deleted old backup: $backup_path"
    fi
  done
fi

echo "[$(date)] Backup done -> $BUCKET/backups/$UPLOAD_NAME"
BACKUP_SCRIPT

  # Replace placeholders
  sed -i.bak \
    -e "s|BUCKET_PLACEHOLDER|${bucket}|" \
    -e "s|REPO_PLACEHOLDER|${openclaw_repo}|" \
    -e "s|RETENTION_PLACEHOLDER|${BACKUP_RETENTION_DAYS:-90}|" \
    -e "s|SECRETS_PREFIX_PLACEHOLDER|${SECRETS_PREFIX:-openclaw}|" \
    "$output"
  rm -f "${output}.bak"
  chmod +x "$output"
}

# ---------------------------------------------------------------------------
# Restore from backup (runs on VM)
# ---------------------------------------------------------------------------
restore_from_backup() {
  local bucket="$1"
  local backup_name="${2:-openclaw-latest.tar.gz}"
  local openclaw_dir="$3"
  local openclaw_repo="$4"

  # Security: ensure sensitive temp files are cleaned up on error
  trap 'rm -f /tmp/openclaw-age-restore.key /tmp/openclaw-restore.tar.gz /tmp/openclaw-restore.tar.gz.age 2>/dev/null; rm -rf /tmp/openclaw-backup-* 2>/dev/null' RETURN

  local backup_url restore_file

  # Try encrypted backup first, fall back to unencrypted
  if [[ "$backup_name" == *.age ]]; then
    # Explicitly requested an encrypted backup
    backup_url="gs://${bucket}/backups/${backup_name}"
    restore_file="/tmp/openclaw-restore.tar.gz.age"
    info "  Downloading encrypted backup: ${backup_name}..."
    gcloud storage cp "$backup_url" "$restore_file" --quiet
  elif gcloud storage cp "gs://${bucket}/backups/${backup_name}.age" "/tmp/openclaw-restore.tar.gz.age" --quiet 2>/dev/null; then
    # Found encrypted version
    restore_file="/tmp/openclaw-restore.tar.gz.age"
    info "  Downloaded encrypted backup: ${backup_name}.age"
  else
    # Fall back to unencrypted
    backup_url="gs://${bucket}/backups/${backup_name}"
    restore_file="/tmp/openclaw-restore.tar.gz"
    info "  Downloading backup: ${backup_name}..."
    gcloud storage cp "$backup_url" "$restore_file" --quiet
  fi

  # Decrypt if backup is encrypted (.age extension)
  if [[ "$restore_file" == *.age ]]; then
    local age_private_key
    age_private_key=$(get_secret "age-private-key" 2>/dev/null || echo "")
    if [ -n "$age_private_key" ]; then
      local key_file="/tmp/openclaw-age-restore.key"
      # Security: create with restrictive permissions from the start (umask in subshell)
      (umask 077; printf '%s' "$age_private_key" > "$key_file")
      age -d -i "$key_file" -o "${restore_file%.age}" "$restore_file"
      rm -f "$restore_file" "$key_file"
      restore_file="${restore_file%.age}"
      info "  Backup decrypted"
    else
      warn "age private key not found — cannot decrypt backup"
      die "Encrypted backup requires age-private-key in Secret Manager"
    fi
  fi

  info "  Extracting..."
  tar -xzf "$restore_file" -C /tmp

  local restore_dir
  restore_dir=$(find /tmp -maxdepth 1 -name 'openclaw-backup-*' -type d -print -quit)
  if [ -z "$restore_dir" ]; then
    die "No backup directory found after extraction"
  fi

  info "  Restoring config and data..."
  mkdir -p "$openclaw_dir" "$openclaw_repo"

  # Restore data directories (uses canonical list from top of file)
  # SYNC: keep in sync with startup.sh (sections 6+7) and providers/gcp/scripts/restore.sh
  for dir in $BACKUP_DATA_DIRS; do
    cp -r "$restore_dir/$dir" "$openclaw_dir/" 2>/dev/null \
      || echo "[WARN] $dir not in backup" >&2
  done

  # Restore openclaw.json
  cp "$restore_dir/openclaw.json" "$openclaw_dir/" 2>/dev/null \
    || warn "openclaw.json not in backup"

  # Restore browser data + strip caches (uses canonical list from top of file)
  cp -r "$restore_dir/browser" "$openclaw_dir/" 2>/dev/null || true
  for cache_dir in "${BROWSER_CACHE_STRIP_DIRS[@]}"; do
    rm -rf "$openclaw_dir/browser/chrome-data/Default/$cache_dir" 2>/dev/null
  done

  # Restore workspace
  mkdir -p "$openclaw_dir/workspace"
  cp -r "$restore_dir/workspace/"* "$openclaw_dir/workspace/" 2>/dev/null || true

  # Restore Docker config
  cp "$restore_dir/docker-compose.yml" "$openclaw_repo/" 2>/dev/null || true
  cp "$restore_dir/docker-compose.override.yml" "$openclaw_repo/" 2>/dev/null || true

  # Restore agent-config.yml
  cp "$restore_dir/agent-config.yml" "$HOME/" 2>/dev/null || true

  # Fix ownership
  chown -R 1000:1000 "$openclaw_dir"

  # Cleanup
  rm -rf "$restore_file" /tmp/openclaw-backup-*

  ok "Restore complete"
}
