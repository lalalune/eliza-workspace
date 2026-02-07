#!/usr/bin/env bash
set -eo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# setup.sh — Full workspace setup: submodules, deps, build
# ═══════════════════════════════════════════════════════════════════════════
#
# One command to go from a fresh clone to a working dev environment.
#
# Usage:
#   scripts/setup.sh           # full setup
#   scripts/setup.sh --skip-build   # skip building (just submodules + deps)
#   scripts/setup.sh --update       # pull latest for all submodules

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SKIP_BUILD=false
UPDATE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=true; shift ;;
    --update)     UPDATE=true; shift ;;
    *)            echo "Unknown option: $1"; exit 1 ;;
  esac
done

cd "$WORKSPACE_DIR"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  eliza-workspace setup"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── Step 1: Submodules ────────────────────────────────────────────────────
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║  1. Initializing submodules                              ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

if [[ "$UPDATE" == "true" ]]; then
  echo "Pulling latest from all submodule remotes..."
  git submodule update --init --recursive --remote
else
  git submodule update --init --recursive
fi

echo ""
echo "Submodule status:"
git submodule foreach --quiet 'echo "  $name @ $(git rev-parse --short HEAD) ($(git branch --show-current 2>/dev/null || echo detached))"'
echo ""

# ── Step 2: Install dependencies ─────────────────────────────────────────
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║  2. Installing dependencies                              ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# eliza — uses bun workspaces
if [[ -d "eliza" && -f "eliza/package.json" ]]; then
  echo "Installing eliza deps (bun)..."
  (cd eliza && bun install) || echo "  Warning: eliza bun install had issues"
  echo ""
fi

# dungeons — uses npm workspaces
if [[ -d "dungeons" && -f "dungeons/package.json" ]]; then
  echo "Installing dungeons deps (npm)..."
  (cd dungeons && npm install) || echo "  Warning: dungeons npm install had issues"
  echo ""
fi

# milaidy — uses npm
if [[ -d "milaidy" && -f "milaidy/package.json" ]]; then
  echo "Installing milaidy deps (npm)..."
  (cd milaidy && npm install) || echo "  Warning: milaidy npm install had issues"
  echo ""
fi

# registry — uses npm (registry/site uses pnpm)
if [[ -d "registry" && -f "registry/package.json" ]]; then
  echo "Installing registry deps (npm)..."
  (cd registry && npm install) || echo "  Warning: registry npm install had issues"
  echo ""
fi

# ── Step 3: Build ─────────────────────────────────────────────────────────
if [[ "$SKIP_BUILD" == "true" ]]; then
  echo "Skipping build (--skip-build)"
else
  echo "╔═══════════════════════════════════════════════════════════╗"
  echo "║  3. Building packages                                    ║"
  echo "╚═══════════════════════════════════════════════════════════╝"
  echo ""

  if [[ -d "eliza" && -f "eliza/package.json" ]]; then
    echo "Building eliza (turbo)..."
    (cd eliza && bun run build) || echo "  Warning: eliza build had issues"
    echo ""
  fi

  if [[ -d "dungeons" && -f "dungeons/package.json" ]]; then
    echo "Building dungeons..."
    (cd dungeons && npm run build) || echo "  Warning: dungeons build had issues"
    echo ""
  fi

  if [[ -d "milaidy" && -f "milaidy/package.json" ]]; then
    echo "Building milaidy..."
    (cd milaidy && npm run build) || echo "  Warning: milaidy build had issues"
    echo ""
  fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Setup complete!"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "  Next steps:"
echo "    bun run dev          # start dev servers"
echo "    bun run dev:eliza    # start just eliza"
echo "    bun run dev:dungeons # start just dungeons"
echo "    bun run dev:milaidy  # start just milaidy"
echo ""
