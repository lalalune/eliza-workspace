#!/usr/bin/env bash
set -o pipefail

# Verify ALL Rust crates are publishable (dry-run only)
# Reports pass/fail for every crate

WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELIZA_DIR="${WORKSPACE_DIR}/eliza"
PLUGINS_DIR="${WORKSPACE_DIR}/plugins"

PASSED=()
FAILED=()
FAILED_DETAILS=()
SKIPPED=()

verify_crate() {
  local dir="$1"
  local name="$2"

  if [[ ! -f "${dir}/Cargo.toml" ]]; then
    SKIPPED+=("${name} (no Cargo.toml)")
    return
  fi

  local version
  version=$(grep '^version' "${dir}/Cargo.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/')

  printf "  %-50s " "${name}@${version}"

  local output
  output=$(cd "$dir" && cargo publish --dry-run --allow-dirty 2>&1)
  local rc=$?

  if [[ $rc -eq 0 ]]; then
    echo "PASS"
    PASSED+=("${name}@${version}")
  else
    echo "FAIL"
    FAILED+=("${name}@${version}")
    # Capture just the error lines
    local errors
    errors=$(echo "$output" | grep -E "^error" | head -5)
    FAILED_DETAILS+=("${name}: ${errors}")
  fi
}

echo ""
echo "================================================================"
echo "  Verifying ALL Rust crates (dry-run publish)"
echo "================================================================"
echo ""

# ── Core packages ─────────────────────────────────────────────────────
echo "── Core Packages ──────────────────────────────────────────────"
verify_crate "${ELIZA_DIR}/packages/rust" "elizaos"
verify_crate "${ELIZA_DIR}/packages/sweagent/rust" "elizaos-sweagent"

# ── All plugins ───────────────────────────────────────────────────────
echo ""
echo "── Plugin Packages ──────────────────────────────────────────────"
for dir in "${PLUGINS_DIR}"/plugin-*/rust; do
  if [[ -d "$dir" && -f "${dir}/Cargo.toml" ]]; then
    crate_name=$(grep '^name' "${dir}/Cargo.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/')
    verify_crate "$dir" "$crate_name"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  VERIFICATION SUMMARY"
echo "================================================================"
echo ""
echo "  PASSED:  ${#PASSED[@]}"
echo "  FAILED:  ${#FAILED[@]}"
echo "  SKIPPED: ${#SKIPPED[@]}"
echo "  TOTAL:   $(( ${#PASSED[@]} + ${#FAILED[@]} + ${#SKIPPED[@]} ))"
echo ""

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "── Failed Crates ──────────────────────────────────────────────"
  for i in "${!FAILED[@]}"; do
    echo ""
    echo "  X ${FAILED[$i]}"
    echo "    ${FAILED_DETAILS[$i]}"
  done
  echo ""
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo "── Skipped ────────────────────────────────────────────────────"
  for s in "${SKIPPED[@]}"; do
    echo "  - $s"
  done
  echo ""
fi

if [[ ${#PASSED[@]} -gt 0 ]]; then
  echo "── Passed Crates ──────────────────────────────────────────────"
  for p in "${PASSED[@]}"; do
    echo "  + $p"
  done
  echo ""
fi
