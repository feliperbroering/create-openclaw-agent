#!/usr/bin/env bash
# Common utilities — colors, logging, prompts, dependency management.
# Sourced by install.sh and setup.sh.

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors (disabled when not a terminal)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'
  DIM='\033[2m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
info()  { echo -e "${BLUE}$*${NC}"; }
ok()    { echo -e "${GREEN}  ✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}  ! $*${NC}"; }
fail()  { echo -e "${RED}  ✗ $*${NC}"; }
step()  { echo -e "\n${BOLD}$*${NC}"; }
dim()   { echo -e "${DIM}  $*${NC}"; }

die() {
  echo -e "${RED}Error: $*${NC}" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------
ask() {
  local prompt="$1" default="${2:-}"
  if [ -n "$default" ]; then
    echo -en "${CYAN}  ? ${prompt} [${default}]: ${NC}" >&2
    read -r answer
    echo "${answer:-$default}"
  else
    echo -en "${CYAN}  ? ${prompt}: ${NC}" >&2
    read -r answer
    echo "$answer"
  fi
}

ask_secret() {
  local prompt="$1"
  echo -en "${CYAN}  ? ${prompt}: ${NC}" >&2
  read -rs answer
  echo >&2
  echo "$answer"
}

confirm() {
  local prompt="$1" default="${2:-Y}"
  local yn
  if [ "$default" = "Y" ]; then
    echo -en "${CYAN}  ? ${prompt} [Y/n]: ${NC}" >&2
  else
    echo -en "${CYAN}  ? ${prompt} [y/N]: ${NC}" >&2
  fi
  read -r yn
  yn="${yn:-$default}"
  [[ "$yn" =~ ^[Yy] ]]
}

choose() {
  local prompt="$1"
  shift
  local options=("$@")
  local i=1

  echo -e "\n${CYAN}  ? ${prompt}${NC}"
  for opt in "${options[@]}"; do
    if [ $i -eq 1 ]; then
      echo -e "    ${BOLD}${GREEN}❯ ${i}) ${opt}${NC}"
    else
      echo -e "      ${i}) ${opt}"
    fi
    ((i++))
  done
  echo -en "${CYAN}    Choice [1]: ${NC}"
  read -r choice
  choice="${choice:-1}"
  echo "${options[$((choice - 1))]}"
}

# ---------------------------------------------------------------------------
# OS Detection
# ---------------------------------------------------------------------------
detect_os() {
  local os
  os="$(uname -s)"
  case "$os" in
    Darwin) echo "macos" ;;
    Linux)
      if [ -f /etc/debian_version ]; then
        echo "debian"
      elif [ -f /etc/redhat-release ]; then
        echo "redhat"
      else
        echo "linux"
      fi
      ;;
    *) echo "unknown" ;;
  esac
}

# ---------------------------------------------------------------------------
# Dependency Management — prompt before install
# ---------------------------------------------------------------------------
check_command() {
  local cmd="$1"
  if command -v "$cmd" &>/dev/null; then
    local version
    version=$("$cmd" --version 2>/dev/null | head -1 || echo "installed")
    ok "$cmd ($version)"
    return 0
  else
    fail "$cmd not found"
    return 1
  fi
}

install_gcloud() {
  local os
  os=$(detect_os)
  case "$os" in
    macos)
      brew install --cask google-cloud-sdk
      ;;
    debian)
      curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
      echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list
      sudo apt-get update -qq && sudo apt-get install -y -qq google-cloud-cli
      ;;
    *)
      die "Please install gcloud CLI manually: https://cloud.google.com/sdk/docs/install"
      ;;
  esac
}

install_tofu() {
  local os
  os=$(detect_os)
  case "$os" in
    macos)
      brew install opentofu
      ;;
    debian)
      curl -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/install-opentofu.sh
      chmod +x /tmp/install-opentofu.sh
      /tmp/install-opentofu.sh --install-method deb
      rm -f /tmp/install-opentofu.sh
      ;;
    *)
      die "Please install OpenTofu manually: https://opentofu.org/docs/intro/install/"
      ;;
  esac
}

install_infracost() {
  local os
  os=$(detect_os)
  case "$os" in
    macos)
      brew install infracost
      ;;
    debian)
      curl -fsSL https://raw.githubusercontent.com/infracost/infracost/master/scripts/install.sh | sh
      ;;
    *)
      die "Please install Infracost manually: https://www.infracost.io/docs/"
      ;;
  esac
}

prompt_install() {
  local name="$1" installer="$2"
  if confirm "Install ${name}?"; then
    info "  Installing ${name}..."
    $installer
    ok "${name} installed"
  else
    echo ""
    case "$name" in
      gcloud) dim "Install manually: https://cloud.google.com/sdk/docs/install" ;;
      tofu)   dim "Install manually: https://opentofu.org/docs/intro/install/" ;;
      *)      dim "Install ${name} and try again." ;;
    esac
    exit 1
  fi
}

check_dependencies() {
  step "Checking dependencies..."

  # Required: git
  check_command git || die "git is required. Install it and try again."

  # Required: curl
  check_command curl || die "curl is required. Install it and try again."

  # gcloud — needed for GCP
  check_command gcloud || prompt_install "gcloud" install_gcloud

  # tofu or terraform
  if ! command -v tofu &>/dev/null && ! command -v terraform &>/dev/null; then
    fail "tofu or terraform not found"
    prompt_install "OpenTofu" install_tofu
  else
    check_command tofu 2>/dev/null || check_command terraform 2>/dev/null || true
  fi

  # Optional: infracost (for cost estimation)
  if ! command -v infracost &>/dev/null; then
    dim "infracost not found (optional — used for cost estimation)"
    if confirm "Install Infracost? (optional)"; then
      install_infracost
    fi
  else
    check_command infracost
  fi

  ok "All dependencies ready"
}

# ---------------------------------------------------------------------------
# Terraform/Tofu wrapper — uses whichever is available
# ---------------------------------------------------------------------------
tf() {
  if command -v tofu &>/dev/null; then
    tofu "$@"
  elif command -v terraform &>/dev/null; then
    terraform "$@"
  else
    die "Neither tofu nor terraform found"
  fi
}

# ---------------------------------------------------------------------------
# Script directory detection
# ---------------------------------------------------------------------------
get_script_dir() {
  local source="${BASH_SOURCE[0]}"
  while [ -L "$source" ]; do
    local dir
    dir=$(cd -P "$(dirname "$source")" && pwd)
    source=$(readlink "$source")
    [[ $source != /* ]] && source="$dir/$source"
  done
  cd -P "$(dirname "$source")" && pwd
}
