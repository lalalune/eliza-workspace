#!/usr/bin/env bash
set -o pipefail

# Publish ALL plugin crates to crates.io with rate-limit handling
# Prerequisites: elizaos, elizaos-sweagent, computeruse-rs already published

WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_DIR="${WORKSPACE_DIR}/plugins"
DELAY_BETWEEN=10  # seconds between publishes to avoid rate limits

PUBLISHED=()
FAILED=()
SKIPPED=()

publish_plugin() {
  local plugin_name="$1"
  local dir="${PLUGINS_DIR}/${plugin_name}/rust"
  
  if [[ ! -f "${dir}/Cargo.toml" ]]; then
    return
  fi

  local crate_name
  crate_name=$(grep '^name' "${dir}/Cargo.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/')
  local version
  version=$(grep '^version' "${dir}/Cargo.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/')

  printf "  %-50s " "${crate_name}@${version}"

  # Temporarily rewrite path deps for publishing
  cp "${dir}/Cargo.toml" "${dir}/Cargo.toml.orig"

  # Rewrite all path deps to version-only
  perl -i -pe '
    s|elizaos = \{ version = "[^"]*", path = "[^"]*"[^}]*\}|elizaos = "2.0.0"|g;
    s|elizaos = \{ path = "[^"]*"[^}]*\}|elizaos = "2.0.0"|g;
    s|elizaos-plugin-mcp = \{ version = "[^"]*", path = "[^"]*"[^}]*\}|elizaos-plugin-mcp = "2.0.0"|g;
    s|computeruse-rs = \{ version = "[^"]*", path = "[^"]*"[^}]*\}|computeruse-rs = "2.0.0"|g;
    s|computeruse-rs = \{ package = "computeruse-rs", version = "[^"]*", path = "[^"]*"[^}]*\}|computeruse-rs = "2.0.0"|g;
  ' "${dir}/Cargo.toml"

  local output
  local rc
  local retries=0
  
  while true; do
    output=$(cd "$dir" && cargo publish --allow-dirty --no-verify 2>&1)
    rc=$?
    
    if [[ $rc -eq 0 ]]; then
      echo "PUBLISHED"
      PUBLISHED+=("${crate_name}")
      break
    fi

    if echo "$output" | grep -q "already uploaded\|already exists"; then
      echo "ALREADY"
      SKIPPED+=("${crate_name} (already)")
      break
    fi

    if echo "$output" | grep -q "429\|Too Many Requests\|rate limit"; then
      retries=$((retries + 1))
      if [[ $retries -gt 3 ]]; then
        echo "RATE-LIMITED (giving up)"
        FAILED+=("${crate_name}: rate limited after 3 retries")
        break
      fi
      echo -n "RATE-LIMITED (retry ${retries}, waiting 60s)... "
      sleep 60
      continue
    fi

    # Other error
    local err
    err=$(echo "$output" | grep "error" | head -1)
    echo "FAILED"
    FAILED+=("${crate_name}: ${err}")
    break
  done

  # Restore original Cargo.toml
  mv "${dir}/Cargo.toml.orig" "${dir}/Cargo.toml"
  
  sleep "$DELAY_BETWEEN"
}

echo ""
echo "================================================================"
echo "  Publishing ALL plugin crates to crates.io"
echo "  Delay between publishes: ${DELAY_BETWEEN}s"
echo "================================================================"
echo ""

for dir in "${PLUGINS_DIR}"/plugin-*/rust; do
  if [[ -d "$dir" && -f "${dir}/Cargo.toml" ]]; then
    plugin_name=$(basename "$(dirname "$dir")")
    publish_plugin "$plugin_name"
  fi
done

echo ""
echo "================================================================"
echo "  SUMMARY"
echo "================================================================"
echo ""
echo "  Published: ${#PUBLISHED[@]}"
echo "  Skipped:   ${#SKIPPED[@]}"
echo "  Failed:    ${#FAILED[@]}"
echo ""

if [[ ${#PUBLISHED[@]} -gt 0 ]]; then
  echo "  PUBLISHED:"
  for p in "${PUBLISHED[@]}"; do
    echo "    + $p"
  done
  echo ""
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "  FAILURES:"
  for f in "${FAILED[@]}"; do
    echo "    X $f"
  done
  echo ""
  exit 1
fi
