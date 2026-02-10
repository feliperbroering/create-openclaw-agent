#!/usr/bin/env bash
# Secrets management — abstract interface for cloud secret managers.
# Each provider implements: provider_store_secret, provider_get_secret,
# provider_delete_secret, provider_list_secrets.
# Sourced by setup.sh.

# ---------------------------------------------------------------------------
# Store a secret value (delegates to active provider)
# Usage: store_secret <name> <value>
# ---------------------------------------------------------------------------
store_secret() {
  local name="$1" value="$2"
  local full_name="${SECRETS_PREFIX:-openclaw}-${name}"
  provider_store_secret "$full_name" "$value"
}

# ---------------------------------------------------------------------------
# Retrieve a secret value (delegates to active provider)
# Usage: get_secret <name>
# ---------------------------------------------------------------------------
get_secret() {
  local name="$1"
  local full_name="${SECRETS_PREFIX:-openclaw}-${name}"
  provider_get_secret "$full_name"
}

# ---------------------------------------------------------------------------
# Store all API keys interactively
# ---------------------------------------------------------------------------
collect_and_store_secrets() {
  step "API Keys"
  dim "Keys are stored securely in your cloud's secret manager."
  dim "They never touch disk in plaintext."
  dim "Tip: set ANTHROPIC_API_KEY, OPENAI_API_KEY, MISTRAL_API_KEY for non-interactive runs."
  echo ""

  local anthropic_key openai_key mistral_key gw_token

  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    anthropic_key="$ANTHROPIC_API_KEY"
    ok "Anthropic API Key (from env)"
  else
    anthropic_key=$(ask_secret "Anthropic API Key (from console.anthropic.com)")
  fi
  [ -z "$anthropic_key" ] && die "Anthropic API Key is required"

  if [ -n "${OPENAI_API_KEY:-}" ]; then
    openai_key="$OPENAI_API_KEY"
    ok "OpenAI API Key (from env)"
  else
    openai_key=$(ask_secret "OpenAI API Key (from platform.openai.com, for Mem0 embeddings)")
  fi
  [ -z "$openai_key" ] && die "OpenAI API Key is required"

  if [ -n "${MISTRAL_API_KEY:-}" ]; then
    mistral_key="$MISTRAL_API_KEY"
    ok "Mistral API Key (from env)"
  else
    mistral_key=$(ask_secret "Mistral API Key (optional, for audio transcription)")
  fi

  gw_token=$(openssl rand -hex 32)
  ok "Generated gateway token"

  step "Storing secrets in ${SECRETS_PROVIDER:-secret manager}..."

  store_secret "anthropic-api-key" "$anthropic_key"
  ok "anthropic-api-key"

  store_secret "openai-api-key" "$openai_key"
  ok "openai-api-key"

  if [ -n "$mistral_key" ]; then
    store_secret "mistral-api-key" "$mistral_key"
    ok "mistral-api-key"
  fi

  store_secret "gateway-token" "$gw_token"
  ok "gateway-token"

  # Generate age encryption keypair for backup encryption
  local age_keypair age_private_key age_public_key
  if command -v age-keygen &>/dev/null; then
    age_keypair=$(age-keygen 2>&1)
    age_private_key=$(echo "$age_keypair" | grep -v "^#")
    age_public_key=$(echo "$age_keypair" | grep "^# public key:" | sed 's/^# public key: //')
  else
    # age-keygen not available locally — keypair will be generated on the VM
    age_private_key=""
    age_public_key=""
    warn "age-keygen not found locally — keypair will be generated on the VM"
  fi

  if [ -n "$age_private_key" ]; then
    store_secret "age-private-key" "$age_private_key"
    ok "age-private-key"
    store_secret "age-public-key" "$age_public_key"
    ok "age-public-key"
  fi

  ok "All secrets stored"
}

# ---------------------------------------------------------------------------
# Migrate secrets from one provider to another
# Usage: migrate_secrets <source_provider_file> <dest_provider_file> <config_file>
# ---------------------------------------------------------------------------
migrate_secrets() {
  step "Secrets Migration"

  local keys
  keys=$(grep "id:" "${CONFIG_FILE:-agent-config.yml}" | sed 's/.*id:\s*//' | tr -d ' ')

  info "Reading secrets from source: ${SOURCE_SECRETS_PROVIDER}..."

  local name value
  local all_ok=true

  for name in $keys; do
    local full_name="${SECRETS_PREFIX:-openclaw}-${name}"
    value=$(provider_get_secret "$full_name" 2>/dev/null || echo "")
    if [ -n "$value" ]; then
      ok "${full_name} (found)"
    else
      fail "${full_name} (NOT FOUND)"
      all_ok=false
    fi
  done

  if [ "$all_ok" = false ]; then
    warn "Some secrets were not found in source. You'll be prompted for missing keys."
  fi

  info "Storing secrets in destination: ${DEST_SECRETS_PROVIDER}..."

  for name in $keys; do
    local full_name="${SECRETS_PREFIX:-openclaw}-${name}"
    value=$(provider_get_secret "$full_name" 2>/dev/null || echo "")
    if [ -n "$value" ]; then
      provider_store_secret "$full_name" "$value"
      ok "${full_name} → created"
    else
      warn "${full_name} — skipped (not found in source)"
    fi
  done

  info "Validating all secrets accessible..."
  for name in $keys; do
    local full_name="${SECRETS_PREFIX:-openclaw}-${name}"
    if provider_get_secret "$full_name" &>/dev/null; then
      ok "${full_name}"
    else
      fail "${full_name} — validation failed"
      die "Secret migration incomplete. Fix and retry."
    fi
  done

  ok "Secrets migrated"
}

# ---------------------------------------------------------------------------
# Validate that all required secrets exist
# ---------------------------------------------------------------------------
validate_secrets() {
  step "Validating secrets..."
  local keys="anthropic-api-key openai-api-key gateway-token"
  local all_ok=true

  for name in $keys; do
    local full_name="${SECRETS_PREFIX:-openclaw}-${name}"
    if provider_get_secret "$full_name" &>/dev/null; then
      ok "${full_name}"
    else
      fail "${full_name} — not found"
      all_ok=false
    fi
  done

  if [ "$all_ok" = false ]; then
    die "Required secrets missing. Run setup again to store them."
  fi

  # Optional: check for age encryption keys (warn but don't fail)
  local age_full_name="${SECRETS_PREFIX:-openclaw}-age-public-key"
  if provider_get_secret "$age_full_name" &>/dev/null; then
    ok "${age_full_name} (backup encryption)"
  else
    warn "${age_full_name} — not found (backups will not be encrypted)"
  fi

  ok "All required secrets present"
}
