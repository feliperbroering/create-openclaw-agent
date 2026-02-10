#!/usr/bin/env bash
# Manual restore script — run on a fresh VM to restore from backup.
#
# Usage:
#   ./restore.sh <bucket-name> [backup-file]
#
# Examples:
#   ./restore.sh my-openclaw-backup
#   ./restore.sh my-openclaw-backup openclaw-20260208-233427.tar.gz
set -euo pipefail

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

# Download
echo "[1/5] Downloading backup..."
gcloud storage cp "$BACKUP_URL" "$RESTORE_FILE" --quiet

# Extract
echo "[2/5] Extracting..."
tar -xzf "$RESTORE_FILE" -C /tmp
RESTORE_DIR=$(ls -d /tmp/openclaw-backup-* 2>/dev/null | head -1)

if [ -z "$RESTORE_DIR" ]; then
  echo "ERROR: No backup directory found after extraction"
  exit 1
fi

# Restore config
echo "[3/5] Restoring config and credentials..."
mkdir -p "$OPENCLAW_DIR" "$OPENCLAW_REPO"

cp "$RESTORE_DIR/openclaw.json" "$OPENCLAW_DIR/" 2>/dev/null || true
cp -r "$RESTORE_DIR/credentials" "$OPENCLAW_DIR/" 2>/dev/null || true
cp -r "$RESTORE_DIR/identity" "$OPENCLAW_DIR/" 2>/dev/null || true
cp -r "$RESTORE_DIR/agents" "$OPENCLAW_DIR/" 2>/dev/null || true
cp -r "$RESTORE_DIR/memory" "$OPENCLAW_DIR/" 2>/dev/null || true
cp -r "$RESTORE_DIR/devices" "$OPENCLAW_DIR/" 2>/dev/null || true
cp -r "$RESTORE_DIR/cron" "$OPENCLAW_DIR/" 2>/dev/null || true

mkdir -p "$OPENCLAW_DIR/workspace"
cp -r "$RESTORE_DIR/workspace/"* "$OPENCLAW_DIR/workspace/" 2>/dev/null || true

# Restore docker infra
echo "[4/5] Restoring Docker config..."
cp "$RESTORE_DIR/docker-env" "$OPENCLAW_REPO/.env" 2>/dev/null || true
cp "$RESTORE_DIR/docker-compose.yml" "$OPENCLAW_REPO/" 2>/dev/null || true
cp "$RESTORE_DIR/docker-compose.override.yml" "$OPENCLAW_REPO/" 2>/dev/null || true

# Cleanup
rm -rf "$RESTORE_FILE" /tmp/openclaw-backup-*

# Start
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
