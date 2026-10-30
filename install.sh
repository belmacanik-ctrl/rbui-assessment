#!/usr/bin/env bash
# =============================================================================
# install.sh — RBUI Assessment Tool Installer
# =============================================================================
set -euo pipefail

SCRIPT_NAME="rbui-check"
INSTALL_DIR="/usr/local/bin"
SCRIPT_SRC="$(dirname "$0")/rbui-check.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'; BOLD='\033[1m'

info()    { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
success() { echo -e "${GREEN}${BOLD}[OK]${RESET}    $*"; }

# Version comes from the script itself so the installer never goes stale
RBUI_VER=$(grep -m1 '^RBUI_VERSION=' "$SCRIPT_SRC" 2>/dev/null | cut -d'"' -f2 || true)
RBUI_VER=${RBUI_VER:-unknown}

echo ""
echo -e "${BOLD}RBUI — RDS/Aurora Resilience Blocker Assessment Tool${RESET}"
echo -e "${BOLD}Installer for rbui-check v${RBUI_VER}${RESET}"
echo "================================================================"
echo ""

# ── Check prerequisites ────────────────────────────────────────────────────
info "Checking prerequisites..."

if ! command -v aws &>/dev/null; then
  warn "AWS CLI not found. Install from: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
else
  AWS_VER=$(aws --version 2>&1 | head -1)
  success "AWS CLI found: $AWS_VER"
fi

if ! command -v jq &>/dev/null; then
  warn "jq not found. Attempting to install..."
  if command -v apt-get &>/dev/null; then
    sudo apt-get install -y jq && success "jq installed via apt"
  elif command -v yum &>/dev/null; then
    sudo yum install -y jq && success "jq installed via yum"
  elif command -v brew &>/dev/null; then
    brew install jq && success "jq installed via brew"
  else
    error "Could not install jq automatically. Please install it manually: https://stedolan.github.io/jq/download/"
  fi
else
  JQ_VER=$(jq --version)
  success "jq found: $JQ_VER"
fi
# dig is optional: used to measure endpoint DNS TTLs (FT-04/FT-05)
if command -v dig &>/dev/null; then
  success "dig found (DNS TTLs will be measured)"
else
  warn "dig not found -- FT-04/FT-05 will be reported as ADVISORY (not measured)."
  warn "  Amazon Linux/RHEL: sudo yum install -y bind-utils   Debian/Ubuntu: sudo apt-get install -y dnsutils"
fi

# ── Check source script exists ─────────────────────────────────────────────
if [[ ! -f "$SCRIPT_SRC" ]]; then
  error "rbui-check.sh not found at $SCRIPT_SRC — run installer from the package directory"
fi

# ── Install ────────────────────────────────────────────────────────────────
info "Installing $SCRIPT_NAME to $INSTALL_DIR ..."

if [[ ! -w "$INSTALL_DIR" ]]; then
  info "Requires sudo to write to $INSTALL_DIR"
  sudo cp "$SCRIPT_SRC" "$INSTALL_DIR/$SCRIPT_NAME"
  sudo chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
else
  cp "$SCRIPT_SRC" "$INSTALL_DIR/$SCRIPT_NAME"
  chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
fi

success "Installed: $INSTALL_DIR/$SCRIPT_NAME"

# ── Verify install ─────────────────────────────────────────────────────────
if command -v "$SCRIPT_NAME" &>/dev/null; then
  INSTALLED_VER=$(grep -m1 '^RBUI_VERSION=' "$(command -v "$SCRIPT_NAME")" 2>/dev/null | cut -d'"' -f2 || true)
  success "Verified: 'rbui-check' v${INSTALLED_VER:-unknown} is available system-wide"
else
  warn "'rbui-check' not found in PATH after install — you may need to run: export PATH=\$PATH:$INSTALL_DIR"
fi

# ── IAM Policy ────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo -e "${BOLD}IAM Setup (read-only — safe for production)${RESET}"
echo "================================================================"
echo ""
echo "  Attach the included iam-policy.json to your IAM user or role:"
echo ""
echo "    aws iam create-policy \\"
echo "      --policy-name RBUI-ReadOnly \\"
echo "      --policy-document file://iam-policy.json"
echo ""
echo "  Then attach it:"
echo "    aws iam attach-user-policy \\"
echo "      --user-name YOUR_USER \\"
echo "      --policy-arn arn:aws:iam::ACCOUNT_ID:policy/RBUI-ReadOnly"
echo ""
echo -e "  ${YELLOW}${BOLD}UPGRADING from v1.3.0 or earlier?${RESET} The policy changed -- v1.3.1+ needs"
echo "  service-quotas:ListAWSDefaultServiceQuotas. Update the EXISTING policy:"
echo ""
echo "    aws iam create-policy-version \\"
echo "      --policy-arn arn:aws:iam::ACCOUNT_ID:policy/RBUI-ReadOnly \\"
echo "      --policy-document file://iam-policy.json \\"
echo "      --set-as-default"
echo ""
echo "  (IAM keeps max 5 versions -- delete an old one first if this fails:"
echo "   aws iam list-policy-versions --policy-arn ...  /  aws iam delete-policy-version ...)"
echo "  Without it, quota limits are reported as 'UNVERIFIED default'."
echo ""

# ── Usage ──────────────────────────────────────────────────────────────────
echo "================================================================"
echo -e "${BOLD}Usage${RESET}"
echo "================================================================"
echo ""
echo "  rbui-check                    # assess us-east-1 (default)"
echo "  rbui-check ca-central-1       # assess specific region"
echo "  rbui-check eu-west-1          # assess another region"
echo "  rbui-check eu-west-1 eu-central-1   # + verify KMS readiness in DR region"
echo ""
echo "  For multiple regions:"
echo "    for r in us-east-1 eu-west-1 ap-southeast-1; do"
echo "      rbui-check \$r; done"
echo ""
echo -e "${GREEN}${BOLD}Installation complete.${RESET}"
echo ""
