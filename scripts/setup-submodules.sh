#!/usr/bin/env bash
set -eo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# setup-submodules.sh — Initialize and update all submodules
# ═══════════════════════════════════════════════════════════════════════════
#
# Clone a fresh workspace:
#   git clone https://github.com/lalalune/eliza-workspace.git
#   cd eliza-workspace
#   scripts/setup-submodules.sh
#
# Or update existing submodules:
#   scripts/setup-submodules.sh --update

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

UPDATE=false
if [[ "${1:-}" == "--update" ]]; then
  UPDATE=true
fi

cd "$WORKSPACE_DIR"

echo "═══════════════════════════════════════════════════════════"
echo "  eliza-workspace: Submodule Setup"
echo "═══════════════════════════════════════════════════════════"
echo ""

if [[ "$UPDATE" == "true" ]]; then
  echo "Updating all submodules..."
  git submodule update --init --recursive --remote
  echo ""
  echo "All submodules updated."
else
  echo "Initializing all submodules..."
  git submodule update --init --recursive
  echo ""
  echo "All submodules initialized."
fi

echo ""
echo "Submodule status:"
git submodule status
echo ""
