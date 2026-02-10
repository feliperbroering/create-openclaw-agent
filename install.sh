#!/usr/bin/env bash
# create-openclaw-agent installer
# Usage: curl -fsSL https://raw.githubusercontent.com/feliperbroering/create-openclaw-agent/main/install.sh | bash
#
# This script:
#   1. Downloads the latest release (or clones main if no releases exist)
#   2. Checks and installs dependencies (with user confirmation)
#   3. Launches the interactive setup wizard
set -euo pipefail

REPO_URL="https://github.com/feliperbroering/create-openclaw-agent"
REPO_API="https://api.github.com/repos/feliperbroering/create-openclaw-agent"
INSTALL_DIR="${HOME}/.create-openclaw-agent"

# Colors
# shellcheck disable=SC2034 # CYAN reserved for future use
if [ -t 1 ]; then
  GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
  GREEN=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

echo -e "${BOLD}"
echo "  create-openclaw-agent"
echo "  Deploy an OpenClaw AI agent to the cloud in minutes."
echo -e "${NC}"

# ---------------------------------------------------------------------------
# Check minimal dependencies (git, curl)
# ---------------------------------------------------------------------------
command -v curl >/dev/null 2>&1 || { echo "Error: curl is required"; exit 1; }

# ---------------------------------------------------------------------------
# Download — prefer tagged release, fallback to main
# ---------------------------------------------------------------------------
download() {
  local release_tag

  # Try to get latest release tag
  release_tag=$(curl -s "${REPO_API}/releases/latest" 2>/dev/null | grep '"tag_name"' | cut -d'"' -f4 || echo "")

  if [ -n "$release_tag" ]; then
    echo -e "${DIM}  Downloading release ${release_tag}...${NC}"
    local tarball="${REPO_URL}/archive/refs/tags/${release_tag}.tar.gz"
    local checksum_url="${REPO_URL}/releases/download/${release_tag}/SHA256SUMS"

    mkdir -p "$INSTALL_DIR"
    curl -fsSL "$tarball" -o /tmp/coa-release.tar.gz

    # Verify checksum if available
    if curl -fsSL "$checksum_url" -o /tmp/coa-sha256 2>/dev/null; then
      if command -v sha256sum &>/dev/null; then
        (cd /tmp && sha256sum -c coa-sha256 2>/dev/null) || echo -e "${DIM}  Checksum verification skipped${NC}"
      fi
      rm -f /tmp/coa-sha256
    fi

    tar -xzf /tmp/coa-release.tar.gz -C "$INSTALL_DIR" --strip-components=1
    rm -f /tmp/coa-release.tar.gz
    echo -e "${GREEN}  ✓ Downloaded ${release_tag}${NC}"
  else
    # No releases yet — clone from main
    echo -e "${DIM}  No releases found, cloning from main...${NC}"
    command -v git >/dev/null 2>&1 || { echo "Error: git is required"; exit 1; }

    if [ -d "$INSTALL_DIR/.git" ]; then
      git -C "$INSTALL_DIR" pull --quiet 2>/dev/null || true
    else
      rm -rf "$INSTALL_DIR"
      git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
    fi
    echo -e "${GREEN}  ✓ Cloned from main${NC}"
  fi
}

download

# ---------------------------------------------------------------------------
# Launch setup wizard
# ---------------------------------------------------------------------------
echo ""
exec bash "${INSTALL_DIR}/setup.sh" "$@"
