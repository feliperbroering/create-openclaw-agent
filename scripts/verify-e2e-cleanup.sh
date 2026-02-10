#!/usr/bin/env bash
# Verify E2E Cleanup — Ensures all test resources were properly expunged.
#
# Checks for any GCP resources with the "teste2e-please-deleat" naming pattern.
# Exit 0 = all clean. Exit 1 = resources found (cleanup incomplete).
#
# Usage:
#   ./scripts/verify-e2e-cleanup.sh
#   ./scripts/verify-e2e-cleanup.sh <project-id>

set -euo pipefail

# Colors
if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  GREEN=''; RED=''; CYAN=''; BOLD=''; NC=''
fi

ok()   { echo -e "${GREEN}  ✓ $*${NC}"; }
fail() { echo -e "${RED}  ✗ $*${NC}"; }
info() { echo -e "${CYAN}  $*${NC}"; }
step() { echo -e "\n${BOLD}$*${NC}"; }

FOUND=0
check_empty() {
  local desc="$1" result="$2"
  if [ -z "$result" ]; then
    ok "$desc — clean"
  else
    fail "$desc — FOUND RESOURCES:"
    echo "$result" | while IFS= read -r line; do
      echo -e "    ${RED}$line${NC}"
    done
    ((FOUND++))
  fi
}

step "E2E Cleanup Verification"
echo ""

# ---------------------------------------------------------------------------
# Check 1: Projects with test naming pattern
# ---------------------------------------------------------------------------
info "Checking for leftover projects..."
# Filter out projects already in DELETE_REQUESTED state (pending 30-day deletion)
PROJECTS=$(gcloud projects list --filter="project_id~teste2e-please-deleat AND lifecycleState=ACTIVE" --format="value(project_id)" 2>/dev/null || echo "")
check_empty "GCP projects with 'teste2e-please-deleat'" "$PROJECTS"

# If a specific project ID was given, do deeper checks
TARGET_PROJECT="${1:-}"
if [ -n "$TARGET_PROJECT" ]; then
  step "Deep check for project: $TARGET_PROJECT"

  # Check if project still exists
  if gcloud projects describe "$TARGET_PROJECT" &>/dev/null 2>&1; then
    fail "Project $TARGET_PROJECT still exists!"
    ((FOUND++))

    # Check resources inside the project
    info "Checking VMs..."
    VMS=$(gcloud compute instances list --project="$TARGET_PROJECT" --format="value(name)" 2>/dev/null || echo "")
    check_empty "Compute instances" "$VMS"

    info "Checking buckets..."
    BUCKETS=$(gcloud storage buckets list --project="$TARGET_PROJECT" --format="value(name)" 2>/dev/null || echo "")
    check_empty "Storage buckets" "$BUCKETS"

    info "Checking secrets..."
    SECRETS=$(gcloud secrets list --project="$TARGET_PROJECT" --format="value(name)" 2>/dev/null || echo "")
    check_empty "Secret Manager secrets" "$SECRETS"

    info "Checking firewall rules..."
    FIREWALLS=$(gcloud compute firewall-rules list --project="$TARGET_PROJECT" --filter="name~openclaw" --format="value(name)" 2>/dev/null || echo "")
    check_empty "Firewall rules" "$FIREWALLS"

    info "Checking service accounts..."
    SAS=$(gcloud iam service-accounts list --project="$TARGET_PROJECT" --filter="email~openclaw" --format="value(email)" 2>/dev/null || echo "")
    check_empty "Service accounts" "$SAS"

    info "Checking NAT routers..."
    ROUTERS=$(gcloud compute routers list --project="$TARGET_PROJECT" --filter="name~openclaw" --format="value(name)" 2>/dev/null || echo "")
    check_empty "Cloud routers" "$ROUTERS"
  else
    ok "Project $TARGET_PROJECT does not exist (deleted)"
  fi
fi

# ---------------------------------------------------------------------------
# Check 2: Buckets with test naming pattern (cross-project)
# ---------------------------------------------------------------------------
info "Checking for leftover buckets globally..."
GLOBAL_BUCKETS=$(gcloud storage buckets list --format="value(name)" 2>/dev/null | grep "teste2e-please-deleat" || echo "")
check_empty "Global buckets with 'teste2e-please-deleat'" "$GLOBAL_BUCKETS"

# ---------------------------------------------------------------------------
# Check 3: Local Terraform state
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_DIR="$ROOT_DIR/providers/gcp/infra"

info "Checking local Terraform state..."
if [ -d "$INFRA_DIR/.terraform" ] || [ -f "$INFRA_DIR/terraform.auto.tfvars" ]; then
  fail "Local Terraform state/config found in $INFRA_DIR"
  ((FOUND++))
else
  ok "No local Terraform state — clean"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
step "Cleanup Verification Result"
echo ""
if [ "$FOUND" -eq 0 ]; then
  ok "ALL CLEAN — no leftover test resources found"
  exit 0
else
  fail "INCOMPLETE CLEANUP — $FOUND resource categories still have leftover data"
  echo ""
  echo -e "${RED}  ACTION REQUIRED: Manually delete the resources listed above.${NC}"
  exit 1
fi
