#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — RBUI Assessment Tool Uninstaller
# =============================================================================
set -euo pipefail

SCRIPT_NAME="rbui-check"
INSTALL_DIR="/usr/local/bin"
TARGET="$INSTALL_DIR/$SCRIPT_NAME"

GREEN='\033[0;32m'; RED='\033[0;31m'; RESET='\033[0m'; BOLD='\033[1m'

echo ""
echo -e "${BOLD}RBUI Uninstaller${RESET}"
echo "================================"

if [[ -f "$TARGET" ]]; then
  if [[ ! -w "$TARGET" ]]; then
    sudo rm -f "$TARGET"
  else
    rm -f "$TARGET"
  fi
  echo -e "${GREEN}[OK]${RESET} Removed $TARGET"
else
  echo -e "${RED}[SKIP]${RESET} $TARGET not found — already removed or never installed"
fi

# Clean up any report files in current directory
REPORTS=$(ls rbui-report-*.txt 2>/dev/null | wc -l | tr -d ' ')
if [[ "$REPORTS" -gt 0 ]]; then
  echo ""
  read -rp "Remove $REPORTS report file(s) from current directory? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    rm -f rbui-report-*.txt
    echo -e "${GREEN}[OK]${RESET} Report files removed"
  fi
fi

echo ""
echo -e "${GREEN}${BOLD}Uninstall complete.${RESET}"
echo ""
