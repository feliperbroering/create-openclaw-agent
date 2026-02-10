#!/usr/bin/env bash
# GCP Provider — implements the provider interface for Google Cloud Platform.
# Sourced by setup.sh when cloud.provider = gcp.

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
provider_check_prerequisites() {
  step "Google Cloud Setup"

  # [1/6] Authentication
  info "[1/6] Google Account"
  if gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>/dev/null | head -1 | grep -q "@"; then
    local account
    account=$(gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>/dev/null | head -1)
    ok "Authenticated as ${account}"
  else
    fail "Not authenticated"
    dim "You need a Google account. Create one at: https://accounts.google.com"
    dim "Then run: gcloud auth login"
    echo ""
    if confirm "Run 'gcloud auth login' now?"; then
      gcloud auth login
    else
      die "Authentication required. Run 'gcloud auth login' and try again."
    fi
    ok "Authenticated"
  fi

  # [2/6] Project
  info "[2/6] GCP Project"
  if [ -z "${GCP_PROJECT_ID:-}" ]; then
    GCP_PROJECT_ID=$(ask "GCP Project ID (or 'new' to create one)")
  fi

  if [ "$GCP_PROJECT_ID" = "new" ]; then
    local project_name
    project_name=$(ask "Project name" "my-openclaw")
    GCP_PROJECT_ID="${project_name}-$(openssl rand -hex 3)"
    info "  Creating project ${GCP_PROJECT_ID}..."
    gcloud projects create "$GCP_PROJECT_ID" --name="$project_name" --quiet
    ok "Project ${GCP_PROJECT_ID} created"
  else
    if gcloud projects describe "$GCP_PROJECT_ID" &>/dev/null; then
      ok "Project ${GCP_PROJECT_ID} exists"
    else
      die "Project ${GCP_PROJECT_ID} not found. Check the ID and try again."
    fi
  fi

  gcloud config set project "$GCP_PROJECT_ID" --quiet

  # [3/6] Billing
  info "[3/6] Billing"
  local billing
  billing=$(gcloud billing projects describe "$GCP_PROJECT_ID" --format="value(billingEnabled)" 2>/dev/null || echo "False")
  if [ "$billing" = "True" ]; then
    ok "Billing enabled"
  else
    fail "No billing account linked"
    echo ""
    dim "Open: https://console.cloud.google.com/billing/linkedaccount?project=${GCP_PROJECT_ID}"
    dim "Link a billing account (credit card required)"
    dim "GCP offers \$300 free trial credit (~12 months of OpenClaw free)"
    echo ""
    echo -en "${CYAN}  Press Enter when billing is enabled...${NC}"
    read -r
    # Verify
    billing=$(gcloud billing projects describe "$GCP_PROJECT_ID" --format="value(billingEnabled)" 2>/dev/null || echo "False")
    if [ "$billing" = "True" ]; then
      ok "Billing enabled"
    else
      die "Billing still not enabled. Please link a billing account and try again."
    fi
  fi

  # [4/6] APIs
  info "[4/6] Required APIs"
  local apis="compute.googleapis.com secretmanager.googleapis.com storage.googleapis.com iap.googleapis.com"
  for api in $apis; do
    local short_name
    short_name=$(echo "$api" | cut -d. -f1)
    if gcloud services list --enabled --filter="name:${api}" --format="value(name)" 2>/dev/null | grep -q "$api"; then
      ok "${short_name}"
    else
      info "  Enabling ${short_name}..."
      gcloud services enable "$api" --quiet
      ok "${short_name}"
    fi
  done

  # [5/6] Bucket
  info "[5/6] GCS Bucket"
  if [ -z "${GCP_BUCKET_NAME:-}" ]; then
    GCP_BUCKET_NAME=$(ask "Bucket name (globally unique)" "${GCP_PROJECT_ID}-openclaw-backup")
  fi

  if gcloud storage buckets describe "gs://${GCP_BUCKET_NAME}" &>/dev/null 2>&1; then
    ok "Bucket gs://${GCP_BUCKET_NAME} exists"
  else
    info "  Creating gs://${GCP_BUCKET_NAME} in ${GCP_REGION}..."
    gcloud storage buckets create "gs://${GCP_BUCKET_NAME}" \
      --location="${GCP_REGION}" \
      --uniform-bucket-level-access \
      --quiet
    ok "Bucket created"
  fi

  # [6/6] ADC
  info "[6/6] Terraform Authentication"
  if gcloud auth application-default print-access-token &>/dev/null 2>&1; then
    ok "Application Default Credentials set"
  else
    info "  Setting up Application Default Credentials..."
    gcloud auth application-default login
    ok "ADC configured"
  fi

  echo ""
  ok "GCP ready!"
}

# ---------------------------------------------------------------------------
# Secrets — Google Secret Manager
# ---------------------------------------------------------------------------
provider_store_secret() {
  local name="$1" value="$2"
  # Create secret if it doesn't exist
  if ! gcloud secrets describe "$name" &>/dev/null 2>&1; then
    gcloud secrets create "$name" \
      --replication-policy=automatic \
      --labels="app=openclaw" \
      --quiet 2>/dev/null
  fi
  # Add new version
  echo -n "$value" | gcloud secrets versions add "$name" --data-file=- --quiet 2>/dev/null
}

provider_get_secret() {
  local name="$1"
  gcloud secrets versions access latest --secret="$name" 2>/dev/null
}

provider_delete_secret() {
  local name="$1"
  gcloud secrets delete "$name" --quiet 2>/dev/null || true
}

provider_list_secrets() {
  gcloud secrets list --filter="labels.app=openclaw" --format="value(name)" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Infrastructure — Terraform/OpenTofu
# ---------------------------------------------------------------------------
provider_provision_infra() {
  local infra_dir="$1"
  local tfvars_file="$2"

  step "Provisioning infrastructure..."

  cd "$infra_dir" || exit

  info "  Initializing Terraform..."
  tf init -backend-config="bucket=${GCP_BUCKET_NAME}" -input=false -no-color 2>&1 | tail -1

  # Import bucket if it already exists (created by prerequisites)
  if gcloud storage buckets describe "gs://${GCP_BUCKET_NAME}" &>/dev/null 2>&1; then
    info "  Importing existing bucket..."
    tf import -var-file="$tfvars_file" -input=false -no-color 'google_storage_bucket.backup' "$GCP_BUCKET_NAME" 2>/dev/null || true
  fi

  info "  Planning..."
  tf plan -var-file="$tfvars_file" -input=false -no-color -out=tfplan 2>&1 | tail -5

  if confirm "Apply infrastructure changes?"; then
    info "  Applying..."
    tf apply -input=false -no-color tfplan 2>&1 | tail -5
    rm -f tfplan
    ok "Infrastructure provisioned"
  else
    rm -f tfplan
    die "Deployment cancelled"
  fi
}

provider_destroy_infra() {
  local infra_dir="$1"
  local tfvars_file="$2"

  cd "$infra_dir" || exit
  tf destroy -var-file="$tfvars_file" -input=false -auto-approve
}

# ---------------------------------------------------------------------------
# SSH
# ---------------------------------------------------------------------------
provider_ssh_command() {
  echo "gcloud compute ssh ${AGENT_NAME:-openclaw-gw} --zone=${GCP_ZONE} --tunnel-through-iap"
}

provider_ssh_exec() {
  local cmd="$1"
  gcloud compute ssh "${AGENT_NAME:-openclaw-gw}" \
    --zone="${GCP_ZONE}" \
    --tunnel-through-iap \
    --command="$cmd" \
    --quiet
}

# ---------------------------------------------------------------------------
# Backup/Restore — GCS
# ---------------------------------------------------------------------------
provider_upload_backup() {
  local local_file="$1" remote_name="$2"
  gcloud storage cp "$local_file" "gs://${GCP_BUCKET_NAME}/backups/${remote_name}" --quiet
}

provider_download_backup() {
  local remote_name="$1" local_file="$2"
  gcloud storage cp "gs://${GCP_BUCKET_NAME}/backups/${remote_name}" "$local_file" --quiet
}

provider_list_backups() {
  gcloud storage ls "gs://${GCP_BUCKET_NAME}/backups/" 2>/dev/null | sort -r
}

# ---------------------------------------------------------------------------
# Wait for VM to be ready
# ---------------------------------------------------------------------------
provider_wait_for_vm() {
  local vm_name="${AGENT_NAME:-openclaw-gw}"
  local zone="${GCP_ZONE}"
  local timeout=180
  local start elapsed

  info "  Waiting for VM to be ready..."
  start=$(date +%s)

  while true; do
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$timeout" ]; then
      fail "Timeout waiting for VM"
      return 1
    fi

    local status
    status=$(gcloud compute instances describe "$vm_name" --zone="$zone" --format="value(status)" 2>/dev/null || echo "")
    if [ "$status" = "RUNNING" ]; then
      ok "VM ${vm_name} is running"
      # Wait a bit more for SSH to be available
      sleep 15
      return 0
    fi

    sleep 10
  done
}

# ---------------------------------------------------------------------------
# Resource validation — warn if VM too small for containers
# ---------------------------------------------------------------------------
provider_check_resources() {
  local machine_type="${GCP_MACHINE_TYPE:-e2-medium}"
  local ram_mb=0

  case "$machine_type" in
    e2-small)      ram_mb=2048 ;;
    e2-medium)     ram_mb=4096 ;;
    e2-standard-2) ram_mb=8192 ;;
    *) ram_mb=4096 ;;
  esac

  # Container limits: gateway=1536M + qdrant=512M + chrome=1024M = 3072M
  local required_mb=3072

  if [ "$ram_mb" -lt "$required_mb" ]; then
    warn "VM ${machine_type} has ${ram_mb}MB RAM but containers need ${required_mb}MB"
    warn "OOM kills are likely. Consider upgrading to e2-medium (4096MB) or larger."
    echo ""
    if ! confirm "Continue anyway?"; then
      die "Choose a larger machine type and try again."
    fi
  fi
}
