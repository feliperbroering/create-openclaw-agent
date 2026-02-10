#!/usr/bin/env bash
# OpenClaw VM startup script (used as GCE metadata startup-script)
#
# This runs on first boot or when the VM is recreated from scratch.
# For existing VMs, Docker restart policy handles container lifecycle.
#
# Variables injected by Terraform templatefile():
#   ${backup_bucket}  — GCS bucket name for backups
#   ${timezone}       — IANA timezone (e.g. America/Sao_Paulo)
#   ${backup_hours}   — Hours between automatic backups
set -euo pipefail

LOG="/var/log/openclaw-startup.log"
exec > >(tee -a "$LOG") 2>&1

echo "[$(date)] OpenClaw startup script begin"

BACKUP_BUCKET="${backup_bucket}"
TIMEZONE="${timezone}"
BACKUP_HOURS="${backup_hours}"

# -------------------------------------------------------------------
# 1. System packages
# -------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq docker.io docker-compose-plugin curl jq
  systemctl enable docker
fi
systemctl start docker

# -------------------------------------------------------------------
# 2. Timezone
# -------------------------------------------------------------------
timedatectl set-timezone "$TIMEZONE"

# -------------------------------------------------------------------
# 3. User setup
# -------------------------------------------------------------------
OPENCLAW_HOME="/home/$(ls /home/ 2>/dev/null | head -1 || echo 'nobody')"
if [ ! -d "$OPENCLAW_HOME" ]; then
  echo "[$(date)] No home directory found yet — will be created on first SSH login"
  exit 0
fi

OPENCLAW_DIR="$OPENCLAW_HOME/.openclaw"
OPENCLAW_REPO="$OPENCLAW_HOME/openclaw"

# -------------------------------------------------------------------
# 4. Install backup script
# -------------------------------------------------------------------
cat > "$OPENCLAW_HOME/openclaw-backup.sh" << BACKUP_EOF
#!/usr/bin/env bash
set -euo pipefail

BUCKET="gs://$BACKUP_BUCKET"
CONTAINER="openclaw-openclaw-gateway-1"
TIMESTAMP=\$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/tmp/openclaw-backup-\$TIMESTAMP"
BACKUP_FILE="/tmp/openclaw-backup-\$TIMESTAMP.tar.gz"
OPENCLAW_REPO="$OPENCLAW_REPO"

echo "[\$(date)] Starting backup..."
mkdir -p "\$BACKUP_DIR/workspace"

docker cp "\$CONTAINER:/home/node/.openclaw/openclaw.json" "\$BACKUP_DIR/" 2>/dev/null || true
docker cp "\$CONTAINER:/home/node/.openclaw/credentials" "\$BACKUP_DIR/credentials" 2>/dev/null || true
docker cp "\$CONTAINER:/home/node/.openclaw/identity" "\$BACKUP_DIR/identity" 2>/dev/null || true
docker cp "\$CONTAINER:/home/node/.openclaw/agents" "\$BACKUP_DIR/agents" 2>/dev/null || true
docker cp "\$CONTAINER:/home/node/.openclaw/memory" "\$BACKUP_DIR/memory" 2>/dev/null || true
docker cp "\$CONTAINER:/home/node/.openclaw/devices" "\$BACKUP_DIR/devices" 2>/dev/null || true
docker cp "\$CONTAINER:/home/node/.openclaw/cron" "\$BACKUP_DIR/cron" 2>/dev/null || true

for f in AGENTS.md SOUL.md USER.md IDENTITY.md TOOLS.md HEARTBEAT.md; do
  docker cp "\$CONTAINER:/home/node/.openclaw/workspace/\$f" "\$BACKUP_DIR/workspace/" 2>/dev/null || true
done
docker cp "\$CONTAINER:/home/node/.openclaw/workspace/memory" "\$BACKUP_DIR/workspace/memory" 2>/dev/null || true

cp "\$OPENCLAW_REPO/.env" "\$BACKUP_DIR/docker-env" 2>/dev/null || true
cp "\$OPENCLAW_REPO/docker-compose.yml" "\$BACKUP_DIR/" 2>/dev/null || true
cp "\$OPENCLAW_REPO/docker-compose.override.yml" "\$BACKUP_DIR/" 2>/dev/null || true

tar -czf "\$BACKUP_FILE" -C /tmp "openclaw-backup-\$TIMESTAMP"
gcloud storage cp "\$BACKUP_FILE" "\$BUCKET/backups/openclaw-\$TIMESTAMP.tar.gz" --quiet
gcloud storage cp "\$BACKUP_FILE" "\$BUCKET/backups/openclaw-latest.tar.gz" --quiet
rm -rf "\$BACKUP_DIR" "\$BACKUP_FILE"

BACKUPS=\$(gcloud storage ls "\$BUCKET/backups/openclaw-2*" 2>/dev/null | sort | head -n -30)
if [ -n "\$BACKUPS" ]; then
  echo "\$BACKUPS" | xargs -I{} gcloud storage rm {} --quiet
fi

echo "[\$(date)] Backup done -> \$BUCKET/backups/openclaw-\$TIMESTAMP.tar.gz"
BACKUP_EOF
chmod +x "$OPENCLAW_HOME/openclaw-backup.sh"

# -------------------------------------------------------------------
# 5. Restore from backup (if no openclaw dir exists)
# -------------------------------------------------------------------
if [ ! -f "$OPENCLAW_DIR/openclaw.json" ]; then
  echo "[$(date)] No openclaw config found — attempting restore from backup"

  BACKUP_URL="gs://$BACKUP_BUCKET/backups/openclaw-latest.tar.gz"
  RESTORE_FILE="/tmp/openclaw-restore.tar.gz"

  if gcloud storage cp "$BACKUP_URL" "$RESTORE_FILE" --quiet 2>/dev/null; then
    echo "[$(date)] Backup downloaded, restoring..."
    mkdir -p "$OPENCLAW_DIR" "$OPENCLAW_REPO"
    tar -xzf "$RESTORE_FILE" -C /tmp

    RESTORE_DIR=$(ls -d /tmp/openclaw-backup-* 2>/dev/null | head -1)
    if [ -n "$RESTORE_DIR" ]; then
      cp "$RESTORE_DIR/openclaw.json" "$OPENCLAW_DIR/" 2>/dev/null || true
      cp -r "$RESTORE_DIR/credentials" "$OPENCLAW_DIR/" 2>/dev/null || true
      cp -r "$RESTORE_DIR/identity" "$OPENCLAW_DIR/" 2>/dev/null || true
      cp -r "$RESTORE_DIR/agents" "$OPENCLAW_DIR/" 2>/dev/null || true
      cp -r "$RESTORE_DIR/memory" "$OPENCLAW_DIR/" 2>/dev/null || true
      cp -r "$RESTORE_DIR/devices" "$OPENCLAW_DIR/" 2>/dev/null || true
      cp -r "$RESTORE_DIR/cron" "$OPENCLAW_DIR/" 2>/dev/null || true

      mkdir -p "$OPENCLAW_DIR/workspace"
      cp -r "$RESTORE_DIR/workspace/"* "$OPENCLAW_DIR/workspace/" 2>/dev/null || true

      cp "$RESTORE_DIR/docker-env" "$OPENCLAW_REPO/.env" 2>/dev/null || true
      cp "$RESTORE_DIR/docker-compose.yml" "$OPENCLAW_REPO/" 2>/dev/null || true
      cp "$RESTORE_DIR/docker-compose.override.yml" "$OPENCLAW_REPO/" 2>/dev/null || true

      chown -R 1000:1000 "$OPENCLAW_DIR"
      echo "[$(date)] Restore complete"
    fi

    rm -rf "$RESTORE_FILE" /tmp/openclaw-backup-*
  else
    echo "[$(date)] No backup found — fresh install needed"
  fi
fi

# -------------------------------------------------------------------
# 6. Start OpenClaw (if docker-compose exists)
# -------------------------------------------------------------------
if [ -f "$OPENCLAW_REPO/docker-compose.yml" ]; then
  echo "[$(date)] Starting OpenClaw..."
  cd "$OPENCLAW_REPO"
  docker compose pull --quiet 2>/dev/null || true
  docker compose up -d
  echo "[$(date)] OpenClaw started"
fi

# -------------------------------------------------------------------
# 7. Setup backup cron
# -------------------------------------------------------------------
BACKUP_SCRIPT="$OPENCLAW_HOME/openclaw-backup.sh"
if [ -f "$BACKUP_SCRIPT" ]; then
  USER=$(ls /home/ | head -1)
  (crontab -u "$USER" -l 2>/dev/null | grep -v openclaw-backup; \
    echo "0 */$BACKUP_HOURS * * * $BACKUP_SCRIPT >> /var/log/openclaw-backup.log 2>&1"; \
    echo "@reboot sleep 300 && $BACKUP_SCRIPT >> /var/log/openclaw-backup.log 2>&1") | crontab -u "$USER" -
  echo "[$(date)] Backup cron configured (every ${BACKUP_HOURS}h)"
fi

echo "[$(date)] OpenClaw startup script complete"
