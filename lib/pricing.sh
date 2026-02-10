#!/usr/bin/env bash
# Cost estimation — cloud infra + LLM API pricing.
# Uses Infracost when available, falls back to hardcoded estimates.
# Sourced by setup.sh.

# ---------------------------------------------------------------------------
# GCP Compute Engine pricing (USD/month, on-demand) — fallback values
# ---------------------------------------------------------------------------
GCP_E2_SMALL_MONTHLY=12.23
GCP_E2_SMALL_1Y_MONTHLY=7.70
GCP_E2_MEDIUM_MONTHLY=24.46
GCP_E2_MEDIUM_1Y_MONTHLY=15.41
GCP_E2_STANDARD2_MONTHLY=48.92
GCP_PD_STANDARD_PER_GB=0.04
GCP_SECRET_PER_VERSION_MONTHLY=0.06
GCP_GCS_PER_GB_MONTHLY=0.02
GCP_NETWORK_ESTIMATE=0.50

# ---------------------------------------------------------------------------
# LLM API pricing (USD per 1M tokens)
# ---------------------------------------------------------------------------
ANTHROPIC_SONNET4_INPUT_PER_1M=3.00
ANTHROPIC_SONNET4_OUTPUT_PER_1M=15.00
ANTHROPIC_HAIKU45_INPUT_PER_1M=1.00
ANTHROPIC_HAIKU45_OUTPUT_PER_1M=5.00
ANTHROPIC_OPUS45_INPUT_PER_1M=5.00
ANTHROPIC_OPUS45_OUTPUT_PER_1M=25.00
OPENAI_EMBEDDING_3S_PER_1M=0.02
MISTRAL_VOXTRAL_PER_MIN=0.03

# ---------------------------------------------------------------------------
# Token usage estimates per message
# ---------------------------------------------------------------------------
AVG_INPUT_TOKENS_PER_MSG=30000
AVG_OUTPUT_TOKENS_PER_MSG=5000
CACHE_HIT_RATE=0.60
MEM0_INPUT_TOKENS_PER_MSG=6000
MEM0_OUTPUT_TOKENS_PER_MSG=1000
EMBEDDING_TOKENS_PER_MSG=500

# ---------------------------------------------------------------------------
# Get VM monthly price
# ---------------------------------------------------------------------------
get_vm_price() {
  local machine_type="${1:-e2-medium}"
  case "$machine_type" in
    e2-small)     echo "$GCP_E2_SMALL_MONTHLY" ;;
    e2-medium)    echo "$GCP_E2_MEDIUM_MONTHLY" ;;
    e2-standard-2) echo "$GCP_E2_STANDARD2_MONTHLY" ;;
    *) echo "$GCP_E2_MEDIUM_MONTHLY" ;;
  esac
}

get_vm_price_1y() {
  local machine_type="${1:-e2-medium}"
  case "$machine_type" in
    e2-small)     echo "$GCP_E2_SMALL_1Y_MONTHLY" ;;
    e2-medium)    echo "$GCP_E2_MEDIUM_1Y_MONTHLY" ;;
    *) echo "$GCP_E2_MEDIUM_1Y_MONTHLY" ;;
  esac
}

# ---------------------------------------------------------------------------
# Get LLM input/output price per 1M tokens
# ---------------------------------------------------------------------------
get_llm_input_price() {
  local model="${1:-anthropic/claude-sonnet-4-20250514}"
  case "$model" in
    *sonnet*)  echo "$ANTHROPIC_SONNET4_INPUT_PER_1M" ;;
    *haiku*)   echo "$ANTHROPIC_HAIKU45_INPUT_PER_1M" ;;
    *opus*)    echo "$ANTHROPIC_OPUS45_INPUT_PER_1M" ;;
    *) echo "$ANTHROPIC_SONNET4_INPUT_PER_1M" ;;
  esac
}

get_llm_output_price() {
  local model="${1:-anthropic/claude-sonnet-4-20250514}"
  case "$model" in
    *sonnet*)  echo "$ANTHROPIC_SONNET4_OUTPUT_PER_1M" ;;
    *haiku*)   echo "$ANTHROPIC_HAIKU45_OUTPUT_PER_1M" ;;
    *opus*)    echo "$ANTHROPIC_OPUS45_OUTPUT_PER_1M" ;;
    *) echo "$ANTHROPIC_SONNET4_OUTPUT_PER_1M" ;;
  esac
}

# ---------------------------------------------------------------------------
# Try Infracost for cloud infra costs (returns total monthly or empty)
# ---------------------------------------------------------------------------
try_infracost() {
  local infra_dir="$1" tfvars_file="$2"
  if ! command -v infracost &>/dev/null; then
    return 1
  fi
  local result
  result=$(infracost breakdown \
    --path "$infra_dir" \
    --terraform-var-file "$tfvars_file" \
    --format json \
    --no-color 2>/dev/null) || return 1
  # Extract total monthly cost
  echo "$result" | grep -o '"totalMonthlyCost":"[^"]*"' | head -1 | cut -d'"' -f4
}

# ---------------------------------------------------------------------------
# Calculate and display cost estimate
# Usage: show_cost_estimate <daily_msgs> <machine_type> <disk_gb> <primary_model> [mem0_enabled] [audio_enabled]
# ---------------------------------------------------------------------------
show_cost_estimate() {
  local daily_msgs="${1:-50}"
  local machine_type="${2:-e2-medium}"
  local disk_gb="${3:-20}"
  local primary_model="${4:-anthropic/claude-sonnet-4-20250514}"
  local mem0_enabled="${5:-true}"
  local audio_enabled="${6:-true}"
  local monthly_msgs=$((daily_msgs * 30))

  # --- Cloud infra ---
  local vm_cost disk_cost gcs_cost secret_cost net_cost infra_total
  local infracost_total=""

  # Try Infracost first for accurate infra pricing
  local infra_dir="${SCRIPT_DIR:-}/providers/gcp/infra"
  local tfvars_file="${infra_dir}/terraform.auto.tfvars"
  if [ -f "$tfvars_file" ] && command -v infracost &>/dev/null; then
    infracost_total=$(try_infracost "$infra_dir" "$tfvars_file" 2>/dev/null || echo "")
  fi

  if [ -n "$infracost_total" ] && [ "$infracost_total" != "0" ]; then
    infra_total="$infracost_total"
    dim "Infra costs from Infracost (live pricing)"
  else
    # Fallback to hardcoded estimates
    vm_cost=$(get_vm_price "$machine_type")
    disk_cost=$(echo "$disk_gb * $GCP_PD_STANDARD_PER_GB" | bc -l 2>/dev/null || echo "0.80")
    gcs_cost=$(echo "1 * $GCP_GCS_PER_GB_MONTHLY" | bc -l 2>/dev/null || echo "0.03")
    secret_cost=$(echo "4 * $GCP_SECRET_PER_VERSION_MONTHLY" | bc -l 2>/dev/null || echo "0.24")
    net_cost="$GCP_NETWORK_ESTIMATE"
    infra_total=$(echo "$vm_cost + $disk_cost + $gcs_cost + $secret_cost + $net_cost" | bc -l 2>/dev/null || echo "26")
  fi

  # --- LLM — main agent ---
  local input_price output_price
  input_price=$(get_llm_input_price "$primary_model")
  output_price=$(get_llm_output_price "$primary_model")

  # Effective input cost with caching
  local effective_input_price
  effective_input_price=$(echo "$input_price * (1 - $CACHE_HIT_RATE) + ($input_price * 0.1) * $CACHE_HIT_RATE" | bc -l 2>/dev/null || echo "1.47")

  local agent_input_tokens=$((monthly_msgs * AVG_INPUT_TOKENS_PER_MSG))
  local agent_output_tokens=$((monthly_msgs * AVG_OUTPUT_TOKENS_PER_MSG))
  local agent_cost
  agent_cost=$(echo "($agent_input_tokens * $effective_input_price / 1000000) + ($agent_output_tokens * $output_price / 1000000)" | bc -l 2>/dev/null || echo "8")

  # --- LLM — Mem0 (only if enabled) ---
  local mem0_cost="0" embed_cost="0"
  if [ "$mem0_enabled" = "true" ]; then
    local mem0_input=$((monthly_msgs * MEM0_INPUT_TOKENS_PER_MSG))
    local mem0_output=$((monthly_msgs * MEM0_OUTPUT_TOKENS_PER_MSG))
    mem0_cost=$(echo "($mem0_input * $ANTHROPIC_HAIKU45_INPUT_PER_1M / 1000000) + ($mem0_output * $ANTHROPIC_HAIKU45_OUTPUT_PER_1M / 1000000)" | bc -l 2>/dev/null || echo "1")

    local embed_tokens=$((monthly_msgs * EMBEDDING_TOKENS_PER_MSG))
    embed_cost=$(echo "$embed_tokens * $OPENAI_EMBEDDING_3S_PER_1M / 1000000" | bc -l 2>/dev/null || echo "0.01")
  fi

  # --- Audio (only if enabled, estimate 30 min/month) ---
  local audio_cost="0"
  if [ "$audio_enabled" = "true" ]; then
    audio_cost=$(echo "30 * $MISTRAL_VOXTRAL_PER_MIN" | bc -l 2>/dev/null || echo "0.90")
  fi

  # --- LLM total ---
  local llm_total
  llm_total=$(echo "$agent_cost + $mem0_cost + $embed_cost + $audio_cost" | bc -l 2>/dev/null || echo "10")

  # --- Grand total ---
  local total
  total=$(echo "$infra_total + $llm_total" | bc -l 2>/dev/null || echo "36")

  # 1-year commitment
  local vm_1y total_1y
  vm_1y=$(get_vm_price_1y "$machine_type")
  vm_cost=${vm_cost:-$(get_vm_price "$machine_type")}
  total_1y=$(echo "$total - $vm_cost + $vm_1y" | bc -l 2>/dev/null || echo "26")

  # --- Display ---
  echo ""
  echo -e "${BOLD}=== Monthly Cost Estimate ===${NC}"
  echo ""

  if [ -n "$infracost_total" ] && [ "$infracost_total" != "0" ]; then
    printf '  %bCloud Infrastructure (GCP)%b\n' "$BOLD" "$NC"
    printf "  └─ Total (via Infracost)         \$%.2f\n" "$infra_total"
  else
    vm_cost=$(get_vm_price "$machine_type")
    disk_cost=$(echo "$disk_gb * $GCP_PD_STANDARD_PER_GB" | bc -l 2>/dev/null || echo "0.80")
    gcs_cost=$(echo "1 * $GCP_GCS_PER_GB_MONTHLY" | bc -l 2>/dev/null || echo "0.03")
    secret_cost=$(echo "4 * $GCP_SECRET_PER_VERSION_MONTHLY" | bc -l 2>/dev/null || echo "0.24")
    net_cost="$GCP_NETWORK_ESTIMATE"
    printf '  %bCloud Infrastructure (GCP)%b\n' "$BOLD" "$NC"
    printf "  ├─ VM %-20s  \$%.2f\n" "$machine_type" "$vm_cost"
    printf "  ├─ Boot disk %dGB pd-standard   \$%.2f\n" "$disk_gb" "$disk_cost"
    printf "  ├─ GCS storage (~1GB backups)   \$%.2f\n" "$gcs_cost"
    printf "  ├─ Secret Manager (4 secrets)   \$%.2f\n" "$secret_cost"
    printf "  └─ Network (IAP, minimal)       \$%.2f\n" "$net_cost"
  fi
  printf '  %bSubtotal infra                 ≈ $%.0f/mo%b\n' "$DIM" "$infra_total" "$NC"
  echo ""

  printf '  %bLLM APIs (~%d msgs/day)%b\n' "$BOLD" "$daily_msgs" "$NC"
  printf "  ├─ %-30s  ≈ \$%.0f\n" "${primary_model##*/} (main agent)" "$agent_cost"
  if [ "$mem0_enabled" = "true" ]; then
    printf "  ├─ Haiku 4.5 (Mem0 extraction)  ≈ \$%.0f\n" "$mem0_cost"
    printf "  ├─ OpenAI embeddings (Mem0)      ≈ \$%.2f\n" "$embed_cost"
  else
    printf "  %b├─ Mem0 (disabled)               \$0%b\n" "$DIM" "$NC"
  fi
  if [ "$audio_enabled" = "true" ]; then
    printf "  └─ Mistral Voxtral (audio)       ≈ \$%.0f\n" "$audio_cost"
  else
    printf "  %b└─ Audio (disabled)              \$0%b\n" "$DIM" "$NC"
  fi
  printf '  %bSubtotal LLM                   ≈ $%.0f/mo%b\n' "$DIM" "$llm_total" "$NC"
  echo ""
  echo "  ─────────────────────────────────────────"
  printf '  %bTOTAL ESTIMATED                 ≈ $%.0f/mo%b\n' "$BOLD" "$total" "$NC"
  echo "  ─────────────────────────────────────────"
  echo ""
  printf '  %bWith 1-year VM commitment:      ≈ $%.0f/mo%b\n' "$DIM" "$total_1y" "$NC"
  echo -e "  ${DIM}GCP free trial (\$300 credit):   ~12 months free${NC}"
  echo ""
  echo -e "  ${DIM}These are estimates. Actual costs depend on usage.${NC}"
  echo ""
}
