#!/usr/bin/env bash
# OpenClaw VM startup script (GCE metadata startup-script)
#
# Runs on every boot. Handles:
#   - System package installation (Docker, etc.)
#   - Secret Manager → tmpfs .env (zero plaintext on disk)
#   - Auto-restore from backup on fresh VM
#   - Container lifecycle
#   - Backup cron setup
#
# Variables injected by Terraform templatefile():
#   ${backup_bucket}    — GCS bucket name for backups
#   ${timezone}         — IANA timezone (e.g. America/Sao_Paulo)
#   ${backup_hours}     — Hours between automatic backups
#   ${secrets_prefix}   — Secret Manager prefix (e.g. openclaw)
#   ${backup_retention} — Days to retain backups
set -euo pipefail

LOG="/var/log/openclaw-startup.log"
exec > >(tee -a "$LOG") 2>&1

echo "[$(date)] OpenClaw startup script begin"

BACKUP_BUCKET="${backup_bucket}"
TIMEZONE="${timezone}"
BACKUP_HOURS="${backup_hours}"
SECRETS_PREFIX="${secrets_prefix}"
BACKUP_RETENTION="${backup_retention}"

# -------------------------------------------------------------------
# 1. System packages
# -------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  echo "[$(date)] Installing Docker and dependencies..."
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
# 3. User setup — create dedicated user if needed
# -------------------------------------------------------------------
OPENCLAW_USER="openclaw"
if ! id "$OPENCLAW_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$OPENCLAW_USER"
  usermod -aG docker "$OPENCLAW_USER"
  echo "[$(date)] Created user $${OPENCLAW_USER}"
fi

OPENCLAW_HOME="/home/$${OPENCLAW_USER}"
OPENCLAW_DIR="$${OPENCLAW_HOME}/.openclaw"
OPENCLAW_REPO="$${OPENCLAW_HOME}/openclaw"

# Also add any OS Login users to docker group
for user_home in /home/*/; do
  local_user=$(basename "$user_home")
  if [ "$local_user" != "$OPENCLAW_USER" ] && id "$local_user" &>/dev/null; then
    usermod -aG docker "$local_user" 2>/dev/null || true
  fi
done

# -------------------------------------------------------------------
# 4. Secrets — fetch from Secret Manager into tmpfs
# -------------------------------------------------------------------
SECRETS_DIR="/run/openclaw-secrets"
if ! mountpoint -q "$SECRETS_DIR" 2>/dev/null; then
  mkdir -p "$SECRETS_DIR"
  mount -t tmpfs -o size=1M,mode=700,uid=1000,gid=1000 tmpfs "$SECRETS_DIR"
fi

echo "[$(date)] Fetching secrets from Secret Manager..."
ANTHROPIC_KEY=$(gcloud secrets versions access latest --secret="$${SECRETS_PREFIX}-anthropic-api-key" 2>/dev/null || echo "")
OPENAI_KEY=$(gcloud secrets versions access latest --secret="$${SECRETS_PREFIX}-openai-api-key" 2>/dev/null || echo "")
MISTRAL_KEY=$(gcloud secrets versions access latest --secret="$${SECRETS_PREFIX}-mistral-api-key" 2>/dev/null || echo "")
GW_TOKEN=$(gcloud secrets versions access latest --secret="$${SECRETS_PREFIX}-gateway-token" 2>/dev/null || echo "")

if [ -z "$ANTHROPIC_KEY" ]; then
  echo "[WARN] ANTHROPIC_API_KEY not found in Secret Manager" >&2
fi

# Write secrets-only .env to tmpfs (RAM only — never persisted to disk)
cat > "$${SECRETS_DIR}/secrets.env" << EOF
ANTHROPIC_API_KEY=$${ANTHROPIC_KEY}
OPENAI_API_KEY=$${OPENAI_KEY}
MISTRAL_API_KEY=$${MISTRAL_KEY}
OPENCLAW_GATEWAY_TOKEN=$${GW_TOKEN}
EOF

echo "[$(date)] Secrets loaded into tmpfs"

# -------------------------------------------------------------------
# 5. Generate non-secret .env + symlink secrets
# -------------------------------------------------------------------
mkdir -p "$${OPENCLAW_REPO}"
cat > "$${OPENCLAW_REPO}/.env" << EOF
# Non-secret configuration (safe on disk)
OPENCLAW_CONFIG_DIR=$${OPENCLAW_DIR}
OPENCLAW_WORKSPACE_DIR=$${OPENCLAW_DIR}/workspace
OPENCLAW_GATEWAY_PORT=18789
OPENCLAW_BRIDGE_PORT=18790
OPENCLAW_GATEWAY_BIND=lan
OPENCLAW_IMAGE=alpine/openclaw

# Secrets loaded from tmpfs (Secret Manager)
$(cat "$${SECRETS_DIR}/secrets.env")

# Note: .env is regenerated every boot from Secret Manager.
# Between boots, the file exists but secrets are fresh each time.
chmod 600 "$${OPENCLAW_REPO}/.env"

# -------------------------------------------------------------------
# 6. Install backup + restart scripts
# -------------------------------------------------------------------
cat > "$${OPENCLAW_HOME}/openclaw-backup.sh" << 'BACKUP_EOF'
#!/usr/bin/env bash
set -euo pipefail

BUCKET="gs://BUCKET_PLACEHOLDER"
CONTAINER="openclaw-openclaw-gateway-1"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/tmp/openclaw-backup-$TIMESTAMP"
BACKUP_FILE="/tmp/openclaw-backup-$TIMESTAMP.tar.gz"
OPENCLAW_REPO="REPO_PLACEHOLDER"
OPENCLAW_DIR="HOME_PLACEHOLDER/.openclaw"
RETENTION_DAYS=RETENTION_PLACEHOLDER

echo "[$(date)] Starting backup..."
mkdir -p "$BACKUP_DIR/workspace"

# Critical: openclaw.json must succeed
if ! docker cp "$CONTAINER:/home/node/.openclaw/openclaw.json" "$BACKUP_DIR/" 2>/dev/null; then
  echo "[WARN] Failed to copy openclaw.json" >&2
fi

# Data directories
for dir in credentials identity agents memory extensions devices cron canvas completions media subagents; do
  docker cp "$CONTAINER:/home/node/.openclaw/$dir" "$BACKUP_DIR/$dir" 2>/dev/null \
    || echo "[WARN] Failed to copy $dir" >&2
done

# Browser data from host — strip caches
cp -r "$OPENCLAW_DIR/browser" "$BACKUP_DIR/browser" 2>/dev/null || echo "[WARN] No browser data" >&2
rm -rf "$BACKUP_DIR/browser/chrome-data/Default/Cache" 2>/dev/null
rm -rf "$BACKUP_DIR/browser/chrome-data/Default/Code Cache" 2>/dev/null
rm -rf "$BACKUP_DIR/browser/chrome-data/Default/Service Worker" 2>/dev/null

# Workspace
for f in AGENTS.md SOUL.md USER.md IDENTITY.md TOOLS.md HEARTBEAT.md; do
  docker cp "$CONTAINER:/home/node/.openclaw/workspace/$f" "$BACKUP_DIR/workspace/" 2>/dev/null || true
done
docker cp "$CONTAINER:/home/node/.openclaw/workspace/memory" "$BACKUP_DIR/workspace/memory" 2>/dev/null || true

# Docker config (NOT .env — secrets stay in Secret Manager)
cp "$OPENCLAW_REPO/docker-compose.yml" "$BACKUP_DIR/" 2>/dev/null || true
cp "$OPENCLAW_REPO/docker-compose.override.yml" "$BACKUP_DIR/" 2>/dev/null || true

# agent-config.yml
cp "HOME_PLACEHOLDER/agent-config.yml" "$BACKUP_DIR/" 2>/dev/null || true

tar -czf "$BACKUP_FILE" -C /tmp "openclaw-backup-$TIMESTAMP"
gcloud storage cp "$BACKUP_FILE" "$BUCKET/backups/openclaw-$TIMESTAMP.tar.gz" --quiet
gcloud storage cp "$BACKUP_FILE" "$BUCKET/backups/openclaw-latest.tar.gz" --quiet
rm -rf "$BACKUP_DIR" "$BACKUP_FILE"

# Retention: delete backups older than configured retention days
CUTOFF_DATE=$(date -d "-$${RETENTION_DAYS} days" +%Y%m%d 2>/dev/null || echo "")
if [ -n "$CUTOFF_DATE" ]; then
  gcloud storage ls "$BUCKET/backups/openclaw-2*" 2>/dev/null | while IFS= read -r backup_path; do
    backup_date=$(echo "$backup_path" | grep -oE '[0-9]{8}' | head -1)
    if [ -n "$backup_date" ] && [ "$backup_date" -lt "$CUTOFF_DATE" ] 2>/dev/null; then
      gcloud storage rm "$backup_path" --quiet
      echo "[$(date)] Deleted old backup: $backup_path"
    fi
  done
fi

echo "[$(date)] Backup done -> $BUCKET/backups/openclaw-$TIMESTAMP.tar.gz"
BACKUP_EOF

sed -i \
  -e "s|BUCKET_PLACEHOLDER|$${BACKUP_BUCKET}|g" \
  -e "s|REPO_PLACEHOLDER|$${OPENCLAW_REPO}|g" \
  -e "s|HOME_PLACEHOLDER|$${OPENCLAW_HOME}|g" \
  -e "s|RETENTION_PLACEHOLDER|$${BACKUP_RETENTION:-90}|g" \
  "$${OPENCLAW_HOME}/openclaw-backup.sh"
chmod +x "$${OPENCLAW_HOME}/openclaw-backup.sh"

# Restart helper — re-fetches secrets from SM and restarts containers
cat > "$${OPENCLAW_HOME}/openclaw-restart.sh" << 'RESTART_EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "Re-running startup script (fetches fresh secrets from Secret Manager)..."
sudo google_metadata_script_runner startup 2>&1 | tail -10
echo "Restarting containers..."
cd REPO_PLACEHOLDER && docker compose down && docker compose up -d
echo "Done. Check: docker compose logs -f"
RESTART_EOF

sed -i "s|REPO_PLACEHOLDER|$${OPENCLAW_REPO}|g" "$${OPENCLAW_HOME}/openclaw-restart.sh"
chmod +x "$${OPENCLAW_HOME}/openclaw-restart.sh"

# -------------------------------------------------------------------
# 7. Restore from backup (if no openclaw config exists)
# -------------------------------------------------------------------
if [ ! -f "$${OPENCLAW_DIR}/openclaw.json" ]; then
  echo "[$(date)] No openclaw config found — attempting restore from backup"

  BACKUP_URL="gs://$${BACKUP_BUCKET}/backups/openclaw-latest.tar.gz"
  RESTORE_FILE="/tmp/openclaw-restore.tar.gz"

  if gcloud storage cp "$BACKUP_URL" "$RESTORE_FILE" --quiet 2>/dev/null; then
    echo "[$(date)] Backup downloaded, restoring..."
    mkdir -p "$OPENCLAW_DIR" "$OPENCLAW_REPO"
    tar -xzf "$RESTORE_FILE" -C /tmp

    RESTORE_DIR=$(ls -d /tmp/openclaw-backup-* 2>/dev/null | head -1)
    if [ -n "$RESTORE_DIR" ]; then
      # Restore data directories
      for dir in credentials identity agents memory extensions devices cron canvas completions media subagents; do
        cp -r "$RESTORE_DIR/$dir" "$OPENCLAW_DIR/" 2>/dev/null \
          || echo "[WARN] $dir not in backup" >&2
      done

      cp "$RESTORE_DIR/openclaw.json" "$OPENCLAW_DIR/" 2>/dev/null \
        || echo "[WARN] openclaw.json not in backup" >&2

      # Browser data + strip caches
      cp -r "$RESTORE_DIR/browser" "$OPENCLAW_DIR/" 2>/dev/null || true
      rm -rf "$OPENCLAW_DIR/browser/chrome-data/Default/Cache" 2>/dev/null
      rm -rf "$OPENCLAW_DIR/browser/chrome-data/Default/Code Cache" 2>/dev/null
      rm -rf "$OPENCLAW_DIR/browser/chrome-data/Default/Service Worker" 2>/dev/null

      # Workspace
      mkdir -p "$OPENCLAW_DIR/workspace"
      cp -r "$RESTORE_DIR/workspace/"* "$OPENCLAW_DIR/workspace/" 2>/dev/null || true

      # Docker config
      cp "$RESTORE_DIR/docker-compose.yml" "$OPENCLAW_REPO/" 2>/dev/null || true
      cp "$RESTORE_DIR/docker-compose.override.yml" "$OPENCLAW_REPO/" 2>/dev/null || true

      # agent-config.yml
      cp "$RESTORE_DIR/agent-config.yml" "$OPENCLAW_HOME/" 2>/dev/null || true

      chown -R 1000:1000 "$OPENCLAW_DIR"
      echo "[$(date)] Restore complete"
    fi

    rm -rf "$RESTORE_FILE" /tmp/openclaw-backup-*
  else
    echo "[$(date)] No backup found — fresh install needed"
  fi
fi

# -------------------------------------------------------------------
# 8. Start containers
# -------------------------------------------------------------------
if [ -f "$${OPENCLAW_REPO}/docker-compose.yml" ]; then
  echo "[$(date)] Starting OpenClaw..."
  cd "$OPENCLAW_REPO"
  docker compose pull --quiet 2>/dev/null || true
  docker compose up -d

  # Configure browser (Chrome sidecar)
  sleep 10
  CONTAINER="openclaw-openclaw-gateway-1"
  if docker ps --format '{{.Names}}' | grep -q "$CONTAINER"; then
    docker exec "$CONTAINER" openclaw config set browser.enabled true 2>/dev/null || true
    docker exec "$CONTAINER" openclaw config set browser.attachOnly true 2>/dev/null || true
    docker exec "$CONTAINER" openclaw config set browser.defaultProfile openclaw 2>/dev/null || true
    docker exec "$CONTAINER" openclaw config set 'browser.profiles.openclaw.cdpUrl' 'http://127.0.0.1:9222' 2>/dev/null || true
    docker exec "$CONTAINER" openclaw config set 'browser.profiles.openclaw.color' '#FF4500' 2>/dev/null || true

    # Install Playwright deps
    docker exec -u root "$CONTAINER" node /app/node_modules/playwright-core/cli.js install-deps chromium 2>/dev/null || true
    docker exec "$CONTAINER" node /app/node_modules/playwright-core/cli.js install chromium 2>/dev/null || true
  fi

  echo "[$(date)] OpenClaw started"
fi

# -------------------------------------------------------------------
# 9. Backup cron
# -------------------------------------------------------------------
BACKUP_SCRIPT="$${OPENCLAW_HOME}/openclaw-backup.sh"
if [ -f "$${BACKUP_SCRIPT}" ]; then
  (crontab -u "$${OPENCLAW_USER}" -l 2>/dev/null | grep -v openclaw-backup; \
    echo "0 */$${BACKUP_HOURS} * * * $${BACKUP_SCRIPT} >> /var/log/openclaw-backup.log 2>&1"; \
    echo "@reboot sleep 300 && $${BACKUP_SCRIPT} >> /var/log/openclaw-backup.log 2>&1") | crontab -u "$${OPENCLAW_USER}" -
  echo "[$(date)] Backup cron configured (every $${BACKUP_HOURS}h)"
fi

echo "[$(date)] OpenClaw startup script complete"
