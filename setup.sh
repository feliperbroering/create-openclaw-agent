#!/usr/bin/env bash
# create-openclaw-agent — Interactive Setup Wizard
#
# Usage:
#   ./setup.sh                          # Interactive wizard
#   ./setup.sh --config agent-config.yml  # Migrate from existing config
#
# Supports three paths:
#   1. New Agent — fresh install from scratch
#   2. Migrate   — move existing agent to new cloud/VM
#   3. Restore   — disaster recovery from backup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/pricing.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
CONFIG_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}  create-openclaw-agent${NC}"
echo -e "${DIM}  Deploy an OpenClaw AI agent to the cloud in minutes.${NC}"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Choose action
# ---------------------------------------------------------------------------
if [ -n "$CONFIG_FILE" ]; then
  ACTION="migrate"
  info "Using config: ${CONFIG_FILE}"
else
  step "What do you want to do?"
  echo ""
  echo -e "    ${BOLD}${GREEN}1) New Agent${NC} — fresh install from scratch"
  echo -e "    2) Migrate — move existing agent to new cloud/VM"
  echo -e "    3) Restore — disaster recovery from backup"
  echo ""
  echo -en "${CYAN}    Choice [1]: ${NC}"
  read -r action_choice
  action_choice="${action_choice:-1}"

  case "$action_choice" in
    1) ACTION="new" ;;
    2) ACTION="migrate" ;;
    3) ACTION="restore" ;;
    *) ACTION="new" ;;
  esac
fi

# ---------------------------------------------------------------------------
# Step 2: Choose cloud provider
# ---------------------------------------------------------------------------
step "Cloud Provider"
echo ""
echo -e "    ${BOLD}${GREEN}1) Google Cloud Platform (GCP)${NC}"
echo -e "    ${DIM}2) Amazon Web Services (coming soon)${NC}"
echo -e "    ${DIM}3) Microsoft Azure (coming soon)${NC}"
echo ""
echo -en "${CYAN}    Choice [1]: ${NC}"
read -r cloud_choice
cloud_choice="${cloud_choice:-1}"

case "$cloud_choice" in
  1)
    CLOUD_PROVIDER="gcp"
    SECRETS_PROVIDER="gcp-secret-manager"
    source "${SCRIPT_DIR}/providers/gcp/provider.sh"
    ;;
  2|3)
    die "This provider is not yet available. Contributions welcome!"
    ;;
  *)
    CLOUD_PROVIDER="gcp"
    SECRETS_PROVIDER="gcp-secret-manager"
    source "${SCRIPT_DIR}/providers/gcp/provider.sh"
    ;;
esac

# ---------------------------------------------------------------------------
# Step 3: Check dependencies
# ---------------------------------------------------------------------------
check_dependencies

# ---------------------------------------------------------------------------
# Step 4: Provider prerequisites + config loading
# ---------------------------------------------------------------------------
if [ "$ACTION" = "migrate" ] && [ -n "$CONFIG_FILE" ]; then
  # Load values from existing config
  GCP_PROJECT_ID=$(config_get "cloud.gcp.project_id" "$CONFIG_FILE")
  GCP_REGION=$(config_get "cloud.gcp.region" "$CONFIG_FILE")
  GCP_ZONE=$(config_get "cloud.gcp.zone" "$CONFIG_FILE")
  GCP_MACHINE_TYPE=$(config_get "cloud.gcp.machine_type" "$CONFIG_FILE")
  GCP_DISK_SIZE=$(config_get "cloud.gcp.disk_size_gb" "$CONFIG_FILE")
  GCP_BUCKET_NAME=$(config_get "cloud.gcp.bucket_name" "$CONFIG_FILE")
  GCP_NETWORK=$(config_get "cloud.gcp.network" "$CONFIG_FILE")
  AGENT_NAME=$(config_get "agent.name" "$CONFIG_FILE")
  TIMEZONE=$(config_get "timezone" "$CONFIG_FILE")
  SECRETS_PREFIX=$(config_get "secrets.prefix" "$CONFIG_FILE")
  PRIMARY_MODEL=$(config_get "agent.model.primary" "$CONFIG_FILE")
  BACKUP_HOURS=$(config_get "backup.interval_hours" "$CONFIG_FILE")
  BACKUP_RETENTION_DAYS=$(config_get "backup.retention_days" "$CONFIG_FILE")
  MEM0_ENABLED=$(config_get "plugins.mem0.enabled" "$CONFIG_FILE")
  AUDIO_ENABLED=$(config_get "tools.audio.enabled" "$CONFIG_FILE")
  BROWSER_ENABLED=$(config_get "tools.browser.enabled" "$CONFIG_FILE")

  info "Loaded config from ${CONFIG_FILE}"

  # Save source provider info for secrets migration
  SOURCE_SECRETS_PROVIDER="$SECRETS_PROVIDER"
  # shellcheck disable=SC2034 # Used during secrets migration
  SOURCE_SECRETS_PREFIX="${SECRETS_PREFIX:-openclaw}"

  # Allow overriding project/region for migration
  step "Migration Target"
  GCP_PROJECT_ID=$(ask "Target GCP Project ID" "$GCP_PROJECT_ID")
  GCP_REGION=$(ask "Target region" "$GCP_REGION")
  GCP_ZONE=$(ask "Target zone" "$GCP_ZONE")
  GCP_BUCKET_NAME=$(ask "Target bucket" "$GCP_BUCKET_NAME")

elif [ "$ACTION" = "restore" ]; then
  # Restore flow: collect minimal info needed
  step "Disaster Recovery"
  echo ""
  dim "Restore requires an existing GCP project with Secret Manager configured."
  dim "The VM will be provisioned and the latest backup restored."
  echo ""

  GCP_REGION=$(ask "Region" "us-central1")
  GCP_ZONE=$(ask "Zone" "${GCP_REGION}-a")
  GCP_BUCKET_NAME=$(ask "GCS bucket with backups" "")
  [ -z "$GCP_BUCKET_NAME" ] && die "Bucket name is required for restore"

  AGENT_NAME=$(ask "VM name" "openclaw-gw")
  GCP_MACHINE_TYPE=$(ask "Machine type" "e2-medium")
  GCP_DISK_SIZE=$(ask "Disk size (GB)" "20")
  GCP_NETWORK=$(ask "VPC network" "default")
  TIMEZONE=$(ask "Timezone (IANA)" "UTC")
  SECRETS_PREFIX=$(ask "Secret Manager prefix" "openclaw")
  BACKUP_HOURS=${BACKUP_HOURS:-6}
  BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-90}
  PRIMARY_MODEL="anthropic/claude-sonnet-4-20250514"
  MEM0_ENABLED="true"
  AUDIO_ENABLED="true"
  BROWSER_ENABLED="true"

  # List available backups so user can choose
  echo ""
  info "Available backups in gs://${GCP_BUCKET_NAME}:"
  AVAILABLE_BACKUPS=$(gcloud storage ls "gs://${GCP_BUCKET_NAME}/backups/" 2>/dev/null | sort -r | head -10 || echo "")
  if [ -z "$AVAILABLE_BACKUPS" ]; then
    die "No backups found in gs://${GCP_BUCKET_NAME}/backups/"
  fi
  echo "$AVAILABLE_BACKUPS"
  echo ""
  # shellcheck disable=SC2034 # Passed to restore script
  RESTORE_BACKUP=$(ask "Backup to restore (filename or 'latest')" "openclaw-latest.tar.gz")
fi

provider_check_prerequisites

# ---------------------------------------------------------------------------
# Step 5: Collect infrastructure config (new install only)
# ---------------------------------------------------------------------------
if [ "$ACTION" = "new" ]; then
  step "Infrastructure Configuration"

  AGENT_NAME=$(ask "Agent name (VM name)" "openclaw-gw")
  GCP_REGION=${GCP_REGION:-$(ask "Region" "us-central1")}
  GCP_ZONE=${GCP_ZONE:-$(ask "Zone" "${GCP_REGION}-a")}
  GCP_MACHINE_TYPE=$(ask "Machine type" "e2-medium")
  GCP_DISK_SIZE=$(ask "Disk size (GB)" "20")
  GCP_NETWORK=$(ask "VPC network" "default")
  TIMEZONE=$(ask "Timezone (IANA)" "UTC")

  # Resource validation
  provider_check_resources
fi

# ---------------------------------------------------------------------------
# Step 6: API Keys and Secrets
# ---------------------------------------------------------------------------
if [ "$ACTION" = "new" ]; then
  SECRETS_PREFIX=$(ask "Secret Manager prefix" "openclaw")
  collect_and_store_secrets

elif [ "$ACTION" = "migrate" ]; then
  SECRETS_PREFIX=${SECRETS_PREFIX:-"openclaw"}
  DEST_SECRETS_PROVIDER="$SECRETS_PROVIDER"

  # Check if secrets need migration (cross-project or cross-cloud)
  if [ "${SOURCE_SECRETS_PROVIDER}" = "${DEST_SECRETS_PROVIDER}" ]; then
    info "Same secrets provider — validating existing secrets..."
    if validate_secrets 2>/dev/null; then
      ok "Secrets accessible in destination"
    else
      warn "Secrets not found in destination — migrating from source..."
      migrate_secrets
    fi
  else
    # Cross-cloud migration
    migrate_secrets
  fi

elif [ "$ACTION" = "restore" ]; then
  # Validate secrets exist in Secret Manager (they are NOT in the backup)
  info "Restore requires secrets to be in Secret Manager already."
  if ! validate_secrets 2>/dev/null; then
    warn "Some secrets are missing. You need to re-enter API keys."
    collect_and_store_secrets
  fi
fi

# ---------------------------------------------------------------------------
# Step 7: Plugins and LLM selection (new install)
# ---------------------------------------------------------------------------
if [ "$ACTION" = "new" ]; then
  step "Agent Configuration"

  PRIMARY_MODEL=$(ask "Primary LLM model" "anthropic/claude-sonnet-4-20250514")

  if confirm "Enable Mem0 persistent memory?" "Y"; then
    MEM0_ENABLED="true"
    MEM0_USER_ID=$(ask "Mem0 user ID (your name)" "default")
    MEM0_LLM_PROVIDER="anthropic"
    MEM0_LLM_MODEL="claude-haiku-4-5-20251001"
  else
    MEM0_ENABLED="false"
  fi

  confirm "Enable audio transcription (Voxtral)?" "Y" && AUDIO_ENABLED="true" || AUDIO_ENABLED="false"
  AUDIO_LANGUAGE="en"
  if [ "$AUDIO_ENABLED" = "true" ]; then
    AUDIO_LANGUAGE=$(ask "Audio language" "en")
  fi

  confirm "Enable browser (Chrome headless)?" "Y" && BROWSER_ENABLED="true" || BROWSER_ENABLED="false"

  confirm "Enable WhatsApp channel?" "Y" && WHATSAPP_ENABLED="true" || WHATSAPP_ENABLED="false"

  BACKUP_HOURS=$(ask "Backup interval (hours)" "6")
  BACKUP_RETENTION_DAYS=$(ask "Backup retention (days)" "90")
fi

# ---------------------------------------------------------------------------
# Step 8: Cost estimate
# ---------------------------------------------------------------------------
if [ "$ACTION" = "new" ] || [ "$ACTION" = "migrate" ]; then
  DAILY_MSGS=$(ask "Estimated daily messages to your agent" "50")
  show_cost_estimate \
    "$DAILY_MSGS" \
    "${GCP_MACHINE_TYPE:-e2-medium}" \
    "${GCP_DISK_SIZE:-20}" \
    "${PRIMARY_MODEL:-anthropic/claude-sonnet-4-20250514}" \
    "${MEM0_ENABLED:-true}" \
    "${AUDIO_ENABLED:-true}"

  if ! confirm "Proceed with deployment?"; then
    die "Deployment cancelled"
  fi
fi

# ---------------------------------------------------------------------------
# Step 9: Generate config files
# ---------------------------------------------------------------------------
step "Generating configuration..."

INFRA_DIR="${SCRIPT_DIR}/providers/gcp/infra"
TFVARS_FILE="${INFRA_DIR}/terraform.auto.tfvars"

# Generate agent-config.yml
config_generate "agent-config.yml"

# Generate terraform.tfvars
config_generate_tfvars "$TFVARS_FILE"

# ---------------------------------------------------------------------------
# Step 10: Provision infrastructure
# ---------------------------------------------------------------------------
provider_provision_infra "$INFRA_DIR" "$TFVARS_FILE"

# ---------------------------------------------------------------------------
# Step 11: Wait for VM and setup
# ---------------------------------------------------------------------------
provider_wait_for_vm

step "Setting up OpenClaw on VM..."

REMOTE_REPO="/home/openclaw/openclaw"
REMOTE_CONFIG="/home/openclaw/.openclaw"

# Ensure openclaw user and directories exist (wait for startup script or create user)
provider_ssh_exec "for i in \$(seq 1 24); do id openclaw 2>/dev/null && break; sudo useradd -m -s /bin/bash openclaw 2>/dev/null && break; sleep 5; done; getent group docker >/dev/null && sudo usermod -aG docker openclaw 2>/dev/null; sudo mkdir -p ${REMOTE_REPO} ${REMOTE_CONFIG} && sudo chown -R openclaw:openclaw /home/openclaw/"

# Download base docker-compose.yml on VM
provider_ssh_exec "sudo -u openclaw bash -c 'cd ${REMOTE_REPO} && curl -fsSL https://raw.githubusercontent.com/anthropics/openclaw/main/docker-compose.yml -o docker-compose.yml'"
ok "docker-compose.yml downloaded on VM"

# Copy override template
gcloud compute scp \
  "${SCRIPT_DIR}/templates/docker-compose.override.example.yml" \
  "${AGENT_NAME:-openclaw-gw}:${REMOTE_REPO}/docker-compose.override.yml" \
  --zone="${GCP_ZONE}" \
  --tunnel-through-iap \
  --quiet 2>/dev/null
ok "docker-compose.override.yml copied"

# Trigger startup script to fetch secrets, generate .env, restore (if needed), start containers
provider_ssh_exec "sudo google_metadata_script_runner startup 2>&1 | tail -20"
ok "Startup script executed"

# ---------------------------------------------------------------------------
# Step 12: Wait for containers + install plugins
# ---------------------------------------------------------------------------
step "Waiting for containers to be healthy..."
# Wait for Docker Compose to pull images and start all 3 containers (gateway, qdrant, chrome)
sleep 30

# Check container status
provider_ssh_exec "cd ${REMOTE_REPO} && docker compose ps --format 'table {{.Name}}\t{{.Status}}'" || true

if [ "${MEM0_ENABLED:-true}" = "true" ]; then
  step "Installing Mem0 plugin..."
  sleep 10  # Extra time for gateway to initialize
  provider_ssh_exec "docker exec openclaw-openclaw-gateway-1 node dist/index.js plugins install @mem0/openclaw-mem0 2>/dev/null" || warn "Mem0 install failed — retry manually"
fi

# ---------------------------------------------------------------------------
# Step 13: Smoke test
# ---------------------------------------------------------------------------
step "Running smoke tests..."
# Brief pause to let containers stabilize after compose reports them as running
sleep 5

# Gateway health
if provider_ssh_exec "docker exec openclaw-openclaw-gateway-1 node -e \"require('http').get('http://localhost:18789/health', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))\"" 2>/dev/null; then
  ok "Gateway responding on port 18789"
else
  warn "Gateway health check failed (may need more time to start)"
fi

# Qdrant health
if provider_ssh_exec "docker exec openclaw-qdrant-1 wget -q --spider http://localhost:6333/healthz" 2>/dev/null; then
  ok "Qdrant responding on port 6333"
else
  warn "Qdrant health check failed"
fi

# Chrome health
if provider_ssh_exec "docker exec openclaw-chrome-1 sh -c 'echo > /dev/tcp/127.0.0.1/9222'" 2>/dev/null; then
  ok "Chrome CDP responding on port 9222"
else
  warn "Chrome CDP health check failed"
fi

# ---------------------------------------------------------------------------
# Step 14: Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}=== Your agent is ready! ===${NC}"
echo ""
echo "  SSH into your VM:"
echo -e "    ${CYAN}$(provider_ssh_command)${NC}"
echo ""
echo "  Configure OpenClaw:"
echo -e "    ${DIM}docker exec -it openclaw-openclaw-gateway-1 node dist/index.js setup${NC}"
echo -e "    ${DIM}docker exec -it openclaw-openclaw-gateway-1 node dist/index.js configure${NC}"
echo ""
echo "  View logs:"
echo -e "    ${DIM}cd ~/openclaw && docker compose logs -f${NC}"
echo ""
echo "  Your config is saved at:"
echo -e "    ${CYAN}./agent-config.yml${NC}"
echo ""
if [ "$ACTION" = "restore" ]; then
  echo -e "  ${YELLOW}NOTE: WhatsApp session may need re-pairing.${NC}"
  echo -e "  ${DIM}docker exec openclaw-openclaw-gateway-1 node dist/index.js channels login${NC}"
  echo ""
fi
echo -e "${DIM}  To migrate later: ./setup.sh --config agent-config.yml${NC}"
echo ""
