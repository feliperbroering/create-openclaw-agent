#!/usr/bin/env bash
# Manual restore script — run on a VM to restore from backup.
#
# Usage:
#   ./restore.sh <bucket-name> [backup-file]
#
# Examples:
#   ./restore.sh my-openclaw-backup
#   ./restore.sh my-openclaw-backup openclaw-20260208-233427.tar.gz
set -euo pipefail

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [ $# -lt 1 ]; then
  echo "Usage: $0 <gcs-bucket-name> [backup-filename]"
  echo ""
  echo "  gcs-bucket-name   Name of the GCS bucket (without gs://)"
  echo "  backup-filename    Optional, defaults to openclaw-latest.tar.gz"
  echo ""
  echo "Examples:"
  echo "  $0 my-openclaw-backup"
  echo "  $0 my-openclaw-backup openclaw-20260208-233427.tar.gz"
  echo ""
  echo "List available backups:"
  echo "  gcloud storage ls gs://<bucket>/backups/"
  exit 1
fi

echo "=== Pre-flight checks ==="

command -v gcloud >/dev/null 2>&1 || { echo "ERROR: gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: Docker not found. Install: apt-get install docker.io docker-compose-plugin"; exit 1; }

if ! gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>/dev/null | grep -q "@"; then
  echo "ERROR: Not authenticated with gcloud. Run: gcloud auth login"
  exit 1
fi

echo "  All checks passed"
echo ""

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BUCKET="gs://$1"
BACKUP_NAME="${2:-openclaw-latest.tar.gz}"
BACKUP_URL="$BUCKET/backups/$BACKUP_NAME"
RESTORE_FILE="/tmp/openclaw-restore.tar.gz"
OPENCLAW_DIR="$HOME/.openclaw"
OPENCLAW_REPO="$HOME/openclaw"

echo "=== OpenClaw Restore ==="
echo "Bucket:  $BUCKET"
echo "Backup:  $BACKUP_NAME"
echo "Target:  $OPENCLAW_DIR"
echo ""

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------
echo "[1/5] Downloading backup..."
gcloud storage cp "$BACKUP_URL" "$RESTORE_FILE" --quiet

# ---------------------------------------------------------------------------
# Extract
# ---------------------------------------------------------------------------
echo "[2/5] Extracting..."
tar -xzf "$RESTORE_FILE" -C /tmp
RESTORE_DIR=$(find /tmp -maxdepth 1 -name 'openclaw-backup-*' -type d -print -quit)

if [ -z "$RESTORE_DIR" ]; then
  echo "ERROR: No backup directory found after extraction"
  exit 1
fi

# ---------------------------------------------------------------------------
# Restore config and data
# ---------------------------------------------------------------------------
echo "[3/5] Restoring config, credentials, and data..."
mkdir -p "$OPENCLAW_DIR" "$OPENCLAW_REPO"

# Restore all data directories
for dir in credentials identity agents memory extensions devices cron canvas completions media subagents; do
  if [ -d "$RESTORE_DIR/$dir" ]; then
    cp -r "$RESTORE_DIR/$dir" "$OPENCLAW_DIR/"
    echo "  ✓ $dir"
  else
    echo "  - $dir (not in backup)"
  fi
done

# openclaw.json
if [ -f "$RESTORE_DIR/openclaw.json" ]; then
  cp "$RESTORE_DIR/openclaw.json" "$OPENCLAW_DIR/"
  echo "  ✓ openclaw.json"
else
  echo "  ! openclaw.json NOT in backup (critical)"
fi

# Browser data + strip caches
if [ -d "$RESTORE_DIR/browser" ]; then
  cp -r "$RESTORE_DIR/browser" "$OPENCLAW_DIR/"
  rm -rf "$OPENCLAW_DIR/browser/chrome-data/Default/Cache" 2>/dev/null
  rm -rf "$OPENCLAW_DIR/browser/chrome-data/Default/Code Cache" 2>/dev/null
  rm -rf "$OPENCLAW_DIR/browser/chrome-data/Default/Service Worker" 2>/dev/null
  echo "  ✓ browser (caches stripped)"
else
  echo "  - browser (not in backup)"
fi

# Workspace
mkdir -p "$OPENCLAW_DIR/workspace"
cp -r "$RESTORE_DIR/workspace/"* "$OPENCLAW_DIR/workspace/" 2>/dev/null || true
echo "  ✓ workspace"

# agent-config.yml
cp "$RESTORE_DIR/agent-config.yml" "$HOME/" 2>/dev/null || true

# Fix ownership
chown -R 1000:1000 "$OPENCLAW_DIR"

# ---------------------------------------------------------------------------
# Docker config
# ---------------------------------------------------------------------------
echo "[4/5] Restoring Docker config..."
cp "$RESTORE_DIR/docker-compose.yml" "$OPENCLAW_REPO/" 2>/dev/null || true
cp "$RESTORE_DIR/docker-compose.override.yml" "$OPENCLAW_REPO/" 2>/dev/null || true

# Note: .env is NOT restored from backup — secrets come from Secret Manager
# The startup script regenerates .env with fresh secrets on every boot.
echo "  Note: API keys loaded from Secret Manager (not from backup)"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm -rf "$RESTORE_FILE" /tmp/openclaw-backup-*

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
echo "[5/5] Starting OpenClaw..."
cd "$OPENCLAW_REPO"
docker compose pull --quiet 2>/dev/null || true
docker compose up -d

echo ""
echo "=== Restore complete ==="
echo ""
echo "Check status:  docker compose logs -f"
echo ""
echo "NOTE: WhatsApp session may need re-pairing."
echo "Run:  docker exec openclaw-openclaw-gateway-1 node dist/index.js channels login"
echo ""
echo "NOTE: If secrets are missing, ensure Secret Manager is configured."
echo "Or run the startup script: sudo google_metadata_script_runner startup"
