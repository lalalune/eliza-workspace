#!/usr/bin/env bash
set -eo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# publish-all.sh — Publish all plugins and packages to npm
# ═══════════════════════════════════════════════════════════════════════════
#
# Orchestrates the full publish in the correct dependency order:
#   1) Plugins (tier 1: no deps, tier 2: plugin deps)
#   2) Packages (foundation -> core -> dependent packages -> computeruse)
#   3) Computeruse-dependent plugins (tier 3)
#   4) Ensures dist-tags are correct
#
# Usage:
#   scripts/publish-all.sh                  # full publish
#   scripts/publish-all.sh --dry-run        # show what would be published
#   scripts/publish-all.sh --tag next       # use a specific dist-tag (default: next)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Forward all arguments to sub-scripts
ARGS=("$@")

echo "═══════════════════════════════════════════════════════════"
echo "  eliza-workspace: Full Publish"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "  Workspace: ${WORKSPACE_DIR}"
echo "  Arguments: ${ARGS[*]:-none}"
echo ""

# ── Step 1: Publish plugins ───────────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║  Step 1/3: Publishing Plugins                            ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
"${SCRIPT_DIR}/publish-plugins.sh" "${ARGS[@]}"

# ── Step 2: Publish packages ─────────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║  Step 2/3: Publishing Packages                           ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
"${SCRIPT_DIR}/publish-packages.sh" "${ARGS[@]}"

# ── Step 3: Ensure dist-tags ─────────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║  Step 3/3: Ensuring dist-tags                            ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
"${SCRIPT_DIR}/ensure-dist-tags.sh" "${ARGS[@]}"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Full publish complete!"
echo "═══════════════════════════════════════════════════════════"
echo ""
