#!/usr/bin/env bash
# E2E test — run setup with API keys from env (avoids typing secrets).
# Requires: ANTHROPIC_API_KEY, OPENAI_API_KEY, GCP_PROJECT_ID
# Optional: MISTRAL_API_KEY, GCP_BUCKET_NAME, GCP_REGION, GCP_ZONE
#
# Usage:
#   export ANTHROPIC_API_KEY=<your-key>
#   export OPENAI_API_KEY=<your-key>
#   export GCP_PROJECT_ID=my-gcp-project
#   ./scripts/run-e2e.sh
#
# You'll still need to interact for: cloud choice, project/bucket (if not set),
# agent name, confirm deploy. API keys are read from env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Pre-flight
[ -z "${ANTHROPIC_API_KEY:-}" ] && { echo "Error: ANTHROPIC_API_KEY required"; exit 1; }
[ -z "${OPENAI_API_KEY:-}" ]   && { echo "Error: OPENAI_API_KEY required"; exit 1; }
[ -z "${GCP_PROJECT_ID:-}" ]   && { echo "Error: GCP_PROJECT_ID required"; exit 1; }

# Defaults for non-secret values (skips prompts when provider checks env)
export GCP_BUCKET_NAME="${GCP_BUCKET_NAME:-${GCP_PROJECT_ID}-openclaw-backup}"
export GCP_REGION="${GCP_REGION:-us-central1}"
export GCP_ZONE="${GCP_ZONE:-${GCP_REGION}-a}"

cd "$ROOT_DIR"
./setup.sh
