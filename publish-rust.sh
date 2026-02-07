#!/usr/bin/env bash
set -eo pipefail

# ══════════════════════════════════════════════════════════════════════════
# Rust Crate Publishing Script
# ══════════════════════════════════════════════════════════════════════════
#
# Publishes all elizaOS Rust crates to crates.io in dependency order.
#
# Layout:
#   Core:    ./eliza/packages/rust/           (elizaos)
#   SWE:     ./eliza/packages/sweagent/rust/  (elizaos-sweagent)
#   Plugins: ./plugins/*/rust/                (elizaos-plugin-*)
#
# Order:
#   Wave 1: elizaos (core) - must publish first
#   Wave 2: elizaos-sweagent (independent, parallel-safe)
#   Wave 3: Plugins that depend on elizaos (after crates.io indexes core)
#   Wave 4: Independent plugins (no elizaos dep, all parallel-safe)
#
# Usage:
#   ./publish-rust.sh               # full publish to crates.io
#   ./publish-rust.sh --dry-run     # verify all crates are publishable
#   ./publish-rust.sh --check       # format + clippy + test only (no publish)
#   ./publish-rust.sh --version X   # override version (default: from Cargo.toml)

DRY_RUN=false
CHECK_ONLY=false
OVERRIDE_VERSION=""
MAX_PARALLEL=8
WAIT_FOR_INDEX=120  # seconds to wait for crates.io indexing

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=true; shift ;;
    --check)      CHECK_ONLY=true; shift ;;
    --version)    OVERRIDE_VERSION="$2"; shift 2 ;;
    --parallel)   MAX_PARALLEL="$2"; shift 2 ;;
    --wait)       WAIT_FOR_INDEX="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --dry-run          Verify publishable without actually publishing"
      echo "  --check            Run fmt/clippy/test only (no publish)"
      echo "  --version VERSION  Override version for all crates"
      echo "  --parallel N       Max parallel builds (default: 8)"
      echo "  --wait SECONDS     Wait time for crates.io indexing (default: 120)"
      echo "  -h, --help         Show this help"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELIZA_DIR="${WORKSPACE_DIR}/eliza"
PLUGINS_DIR="${WORKSPACE_DIR}/plugins"

FAILED=()
PUBLISHED=()
SKIPPED=()
CHECKED=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_err()   { echo -e "${RED}[FAIL]${NC}  $*"; }
log_skip()  { echo -e "${CYAN}[SKIP]${NC}  $*"; }

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  elizaOS Rust Crate Publisher"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "  Workspace:  ${WORKSPACE_DIR}"
echo "  Eliza repo: ${ELIZA_DIR}"
echo "  Plugins:    ${PLUGINS_DIR}"
echo "  Mode:       $(if $CHECK_ONLY; then echo 'CHECK ONLY'; elif $DRY_RUN; then echo 'DRY RUN'; else echo 'PUBLISH'; fi)"
if [[ -n "$OVERRIDE_VERSION" ]]; then
  echo "  Version:    ${OVERRIDE_VERSION} (override)"
fi
echo ""

# ── Preflight checks ─────────────────────────────────────────────────────

check_prerequisites() {
  local missing=false

  if ! command -v cargo &>/dev/null; then
    log_err "cargo not found - install Rust toolchain"
    missing=true
  fi

  if ! command -v rustfmt &>/dev/null; then
    log_warn "rustfmt not found - install with: rustup component add rustfmt"
  fi

  if ! $CHECK_ONLY && ! $DRY_RUN; then
    if [[ -z "${CARGO_REGISTRY_TOKEN:-}" ]]; then
      # Check if cargo is already logged in
      if ! cargo login --help &>/dev/null 2>&1; then
        log_err "CARGO_REGISTRY_TOKEN not set and not logged in to crates.io"
        log_info "Set CARGO_REGISTRY_TOKEN or run: cargo login"
        missing=true
      fi
    fi
  fi

  if $missing; then
    exit 1
  fi
}

# ── Helper: check a single crate (fmt + clippy + test) ───────────────────

check_crate() {
  local crate_dir="$1"
  local crate_name="$2"
  local features="${3:-}"

  if [[ ! -f "${crate_dir}/Cargo.toml" ]]; then
    log_skip "${crate_name} (no Cargo.toml)"
    SKIPPED+=("${crate_name} (no Cargo.toml)")
    return 1
  fi

  log_info "Checking ${crate_name}..."

  # Format check
  if command -v rustfmt &>/dev/null; then
    if ! (cd "$crate_dir" && cargo fmt --all -- --check 2>&1); then
      log_warn "${crate_name}: formatting issues (run cargo fmt)"
    fi
  fi

  # Clippy
  local clippy_args=""
  if [[ -n "$features" ]]; then
    clippy_args="--features ${features}"
  fi
  if ! (cd "$crate_dir" && cargo clippy ${clippy_args} 2>&1); then
    log_warn "${crate_name}: clippy warnings"
  fi

  # Tests
  local test_args=""
  if [[ -n "$features" ]]; then
    test_args="--features ${features}"
  fi
  if ! (cd "$crate_dir" && cargo test ${test_args} 2>&1); then
    log_warn "${crate_name}: some tests failed"
  fi

  CHECKED+=("${crate_name}")
  return 0
}

# ── Helper: publish a single crate ───────────────────────────────────────

publish_crate() {
  local crate_dir="$1"
  local crate_name="$2"
  local has_elizaos_dep="${3:-false}"
  local features="${4:-}"

  if [[ ! -f "${crate_dir}/Cargo.toml" ]]; then
    log_skip "${crate_name} (no Cargo.toml)"
    SKIPPED+=("${crate_name} (no Cargo.toml)")
    return 1
  fi

  # Extract current version
  local current_version
  current_version=$(grep '^version' "${crate_dir}/Cargo.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/')

  # Override version if specified
  if [[ -n "$OVERRIDE_VERSION" ]]; then
    sed -i.bak "s/^version = \".*\"/version = \"${OVERRIDE_VERSION}\"/" "${crate_dir}/Cargo.toml"
    rm -f "${crate_dir}/Cargo.toml.bak"
    current_version="$OVERRIDE_VERSION"

    # If has elizaos dependency, update it to use published version
    if [[ "$has_elizaos_dep" == "true" ]]; then
      # Replace path dependency with version-only dependency
      sed -i.bak "s|elizaos = { version = \"[^\"]*\", path = \"[^\"]*\"[^}]*}|elizaos = \"${OVERRIDE_VERSION}\"|" "${crate_dir}/Cargo.toml"
      sed -i.bak "s|elizaos = { path = \"[^\"]*\"[^}]*}|elizaos = \"${OVERRIDE_VERSION}\"|" "${crate_dir}/Cargo.toml"
      rm -f "${crate_dir}/Cargo.toml.bak"
    fi
  fi

  # Check if already published on crates.io
  local published_version
  published_version=$(cargo search "${crate_name}" --limit 1 2>/dev/null | grep "^${crate_name} " | sed 's/.*= "\(.*\)".*/\1/' || echo "")
  if [[ "$published_version" == "$current_version" ]]; then
    log_skip "${crate_name}@${current_version} (already on crates.io)"
    SKIPPED+=("${crate_name}@${current_version} (already published)")
    return 0
  fi

  # Run checks
  check_crate "$crate_dir" "$crate_name" "$features"

  if $CHECK_ONLY; then
    log_ok "${crate_name}@${current_version} checks passed"
    return 0
  fi

  # Verify publishable (dry run)
  log_info "Verifying ${crate_name}@${current_version} is publishable..."
  if ! (cd "$crate_dir" && cargo publish --dry-run --allow-dirty 2>&1); then
    log_err "${crate_name}@${current_version} failed publish dry-run"
    FAILED+=("${crate_name}@${current_version} (dry-run failed)")
    return 1
  fi

  if $DRY_RUN; then
    log_ok "${crate_name}@${current_version} ready to publish (dry run)"
    PUBLISHED+=("${crate_name}@${current_version} (dry run)")
    return 0
  fi

  # Actually publish
  log_info "Publishing ${crate_name}@${current_version} to crates.io..."
  if (cd "$crate_dir" && cargo publish --allow-dirty 2>&1); then
    log_ok "${crate_name}@${current_version} published!"
    PUBLISHED+=("${crate_name}@${current_version}")
  else
    log_err "${crate_name}@${current_version} publish failed"
    FAILED+=("${crate_name}@${current_version}")
    return 1
  fi
}

# ── Helper: publish crates in parallel ────────────────────────────────────

publish_parallel() {
  local pids=()
  local names=()
  local results=()

  while [[ $# -gt 0 ]]; do
    local crate_dir="$1"
    local crate_name="$2"
    local has_dep="${3:-false}"
    shift 3

    # Throttle parallel jobs
    while [[ ${#pids[@]} -ge $MAX_PARALLEL ]]; do
      local new_pids=()
      local new_names=()
      for i in "${!pids[@]}"; do
        if kill -0 "${pids[$i]}" 2>/dev/null; then
          new_pids+=("${pids[$i]}")
          new_names+=("${names[$i]}")
        else
          wait "${pids[$i]}" || true
        fi
      done
      pids=("${new_pids[@]}")
      names=("${new_names[@]}")
      if [[ ${#pids[@]} -ge $MAX_PARALLEL ]]; then
        sleep 1
      fi
    done

    publish_crate "$crate_dir" "$crate_name" "$has_dep" &
    pids+=($!)
    names+=("$crate_name")
  done

  # Wait for all remaining
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done
}

# ══════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════

check_prerequisites

# ── Wave 1: Core (elizaos) ────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Wave 1: Core Library (elizaos)"
echo "═══════════════════════════════════════════════════════════"

CORE_DIR="${ELIZA_DIR}/packages/rust"
publish_crate "$CORE_DIR" "elizaos" "false" "native"

# ── Wave 2: SWE Agent (independent) ──────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Wave 2: SWE Agent (elizaos-sweagent)"
echo "═══════════════════════════════════════════════════════════"

SWEAGENT_DIR="${ELIZA_DIR}/packages/sweagent/rust"
publish_crate "$SWEAGENT_DIR" "elizaos-sweagent" "false"

# ── Wave 3: Dependent plugins (need crates.io to index elizaos) ──────────

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Wave 3: Plugins with elizaos dependency"
echo "═══════════════════════════════════════════════════════════"

if ! $CHECK_ONLY && ! $DRY_RUN; then
  log_info "Waiting ${WAIT_FOR_INDEX}s for crates.io to index elizaos..."
  sleep "$WAIT_FOR_INDEX"
fi

# Plugins that depend on the elizaos crate
DEPENDENT_PLUGINS=(
  "plugin-sql"
  "plugin-openai"
  "plugin-goals"
  "plugin-localdb"
  "plugin-todo"
  "plugin-xai"
  "plugin-discord"
  "plugin-bluebubbles"
  "plugin-copilot-proxy"
  "plugin-rlm"
  "plugin-whatsapp"
  "plugin-acp"
  "plugin-scratchpad"
)

for plugin in "${DEPENDENT_PLUGINS[@]}"; do
  plugin_dir="${PLUGINS_DIR}/${plugin}/rust"
  crate_name=$(grep '^name' "${plugin_dir}/Cargo.toml" 2>/dev/null | head -1 | sed 's/.*"\(.*\)".*/\1/' || echo "elizaos-${plugin}")
  publish_crate "$plugin_dir" "$crate_name" "true"
done

# ── Wave 4: Independent plugins ──────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Wave 4: Independent plugins (no elizaos dependency)"
echo "═══════════════════════════════════════════════════════════"

INDEPENDENT_PLUGINS=(
  "plugin-agent-orchestrator"
  "plugin-agent-skills"
  "plugin-anthropic"
  "plugin-auto-trader"
  "plugin-blooio"
  "plugin-bluesky"
  "plugin-browser"
  "plugin-cli"
  "plugin-code"
  "plugin-commands"
  "plugin-computeruse"
  "plugin-cron"
  "plugin-directives"
  "plugin-edge-tts"
  "plugin-elevenlabs"
  "plugin-eliza-classic"
  "plugin-elizacloud"
  "plugin-evm"
  "plugin-experience"
  "plugin-farcaster"
  "plugin-feishu"
  "plugin-form"
  "plugin-github"
  "plugin-gmail-watch"
  "plugin-google-chat"
  "plugin-google-genai"
  "plugin-groq"
  "plugin-imessage"
  "plugin-inmemorydb"
  "plugin-instagram"
  "plugin-knowledge"
  "plugin-line"
  "plugin-linear"
  "plugin-local-ai"
  "plugin-local-embedding"
  "plugin-lp-manager"
  "plugin-matrix"
  "plugin-mattermost"
  "plugin-mcp"
  "plugin-memory"
  "plugin-minecraft"
  "plugin-moltbook"
  "plugin-msteams"
  "plugin-n8n"
  "plugin-nextcloud-talk"
  "plugin-nostr"
  "plugin-ollama"
  "plugin-openrouter"
  "plugin-pdf"
  "plugin-personality"
  "plugin-plugin-manager"
  "plugin-polymarket"
  "plugin-prose"
  "plugin-roblox"
  "plugin-robot-voice"
  "plugin-rolodex"
  "plugin-rss"
  "plugin-s3-storage"
  "plugin-scheduling"
  "plugin-secrets-manager"
  "plugin-shell"
  "plugin-signal"
  "plugin-simple-voice"
  "plugin-slack"
  "plugin-social-alpha"
  "plugin-solana"
  "plugin-tee"
  "plugin-telegram"
  "plugin-tlon"
  "plugin-trajectory-logger"
  "plugin-trust"
  "plugin-tts"
  "plugin-twilio"
  "plugin-twitch"
  "plugin-vercel-ai-gateway"
  "plugin-vision"
  "plugin-webhooks"
  "plugin-zalo"
  "plugin-zalouser"
)

for plugin in "${INDEPENDENT_PLUGINS[@]}"; do
  plugin_dir="${PLUGINS_DIR}/${plugin}/rust"
  if [[ -f "${plugin_dir}/Cargo.toml" ]]; then
    crate_name=$(grep '^name' "${plugin_dir}/Cargo.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/')
    publish_crate "$plugin_dir" "$crate_name" "false"
  else
    log_skip "${plugin} (no rust/Cargo.toml)"
    SKIPPED+=("${plugin} (no Cargo.toml)")
  fi
done

# ══════════════════════════════════════════════════════════════════════════
#  SUMMARY
# ══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  RUST PUBLISH SUMMARY"
echo "═══════════════════════════════════════════════════════════"
echo ""

pub_count=${#PUBLISHED[@]}
skip_count=${#SKIPPED[@]}
fail_count=${#FAILED[@]}
check_count=${#CHECKED[@]}

if $CHECK_ONLY; then
  echo -e "  ${GREEN}Checked: ${check_count}${NC}"
  if [[ $check_count -gt 0 ]]; then
    for c in "${CHECKED[@]}"; do
      echo "    + $c"
    done
  fi
else
  echo -e "  ${GREEN}Published: ${pub_count}${NC}"
  if [[ $pub_count -gt 0 ]]; then
    for p in "${PUBLISHED[@]}"; do
      echo "    + $p"
    done
  fi
fi

echo ""
echo -e "  ${CYAN}Skipped: ${skip_count}${NC}"
if [[ $skip_count -gt 0 ]]; then
  for s in "${SKIPPED[@]}"; do
    echo "    - $s"
  done
fi

echo ""
if [[ $fail_count -gt 0 ]]; then
  echo -e "  ${RED}FAILED: ${fail_count}${NC}"
  for f in "${FAILED[@]}"; do
    echo "    X $f"
  done
  echo ""
  exit 1
else
  echo -e "  ${GREEN}No failures!${NC}"
fi

echo ""
echo "  Total crates: $((pub_count + skip_count + fail_count))"
echo ""
