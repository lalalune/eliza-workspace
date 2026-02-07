#!/usr/bin/env bash
set -eo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# dev.sh — Start dev servers for workspace submodules
# ═══════════════════════════════════════════════════════════════════════════
#
# Starts dev mode in sub-packages that support it.
# By default starts all; pass a target to start only that one.
#
# Usage:
#   scripts/dev.sh              # start all dev servers
#   scripts/dev.sh eliza        # start only eliza
#   scripts/dev.sh dungeons     # start only dungeons
#   scripts/dev.sh milaidy      # start only milaidy

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET="${1:-all}"

cd "$WORKSPACE_DIR"

# ── Pids for cleanup ─────────────────────────────────────────────────────
PIDS=()

cleanup() {
  echo ""
  echo "Shutting down dev servers..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null
  echo "All dev servers stopped."
  exit 0
}

trap cleanup SIGINT SIGTERM

# ── Dev launchers ─────────────────────────────────────────────────────────
start_eliza() {
  if [[ -d "eliza" && -f "eliza/package.json" ]]; then
    echo "Starting eliza dev (bun run start)..."
    (cd eliza && bun run start) &
    PIDS+=($!)
  else
    echo "Warning: eliza submodule not found"
  fi
}

start_dungeons() {
  if [[ -d "dungeons" && -f "dungeons/package.json" ]]; then
    echo "Starting dungeons dev (npm run dev)..."
    (cd dungeons && npm run dev) &
    PIDS+=($!)
  else
    echo "Warning: dungeons submodule not found"
  fi
}

start_milaidy() {
  if [[ -d "milaidy" && -f "milaidy/package.json" ]]; then
    echo "Starting milaidy dev (npm run dev)..."
    (cd milaidy && npm run dev) &
    PIDS+=($!)
  else
    echo "Warning: milaidy submodule not found"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  eliza-workspace dev"
echo "═══════════════════════════════════════════════════════════"
echo ""

case "$TARGET" in
  all)
    start_eliza
    start_dungeons
    start_milaidy
    ;;
  eliza)
    start_eliza
    ;;
  dungeons)
    start_dungeons
    ;;
  milaidy)
    start_milaidy
    ;;
  *)
    echo "Unknown target: $TARGET"
    echo "Usage: scripts/dev.sh [all|eliza|dungeons|milaidy]"
    exit 1
    ;;
esac

if [[ ${#PIDS[@]} -eq 0 ]]; then
  echo "No dev servers started."
  exit 1
fi

echo ""
echo "Dev servers running (Ctrl+C to stop all):"
for pid in "${PIDS[@]}"; do
  echo "  PID $pid"
done
echo ""

# Wait for all background processes
wait
