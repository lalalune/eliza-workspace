#!/usr/bin/env bash
set -eo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# publish-packages.sh — Publish all @elizaos packages to npm
# ═══════════════════════════════════════════════════════════════════════════
#
# Publishes packages from ./eliza/packages/ in dependency order.
#
# Usage:
#   scripts/publish-packages.sh                  # full publish
#   scripts/publish-packages.sh --dry-run        # show what would be published
#   scripts/publish-packages.sh --tag next       # use a specific dist-tag (default: next)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ELIZA_DIR="${WORKSPACE_DIR}/eliza"

DRY_RUN=false
TAG="next"
FAILED=()
PUBLISHED=()
SKIPPED=()

# ── Parse arguments ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; shift ;;
    --tag)       TAG="$2"; shift 2 ;;
    *)           echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ "$DRY_RUN" == "true" ]]; then
  echo "=== DRY RUN MODE ==="
fi

echo ""
echo "Workspace:  ${WORKSPACE_DIR}"
echo "Eliza dir:  ${ELIZA_DIR}"
echo "Tag:        ${TAG}"
echo ""

if [[ ! -d "$ELIZA_DIR" ]]; then
  echo "ERROR: eliza directory not found at ${ELIZA_DIR}"
  exit 1
fi

# ── Helper: publish a single package ──────────────────────────────────────
publish_pkg() {
  local pkg_dir="$1"
  local pkg_json="${pkg_dir}/package.json"

  if [[ ! -f "$pkg_json" ]]; then
    return
  fi

  local name version private_field
  name=$(node -e "console.log(require('${pkg_json}').name || '')")
  version=$(node -e "console.log(require('${pkg_json}').version || '')")
  private_field=$(node -e "console.log(require('${pkg_json}').private === true ? 'true' : 'false')")

  if [[ -z "$name" || -z "$version" ]]; then
    return
  fi

  if [[ "$private_field" == "true" ]]; then
    SKIPPED+=("$name@$version (private)")
    return
  fi

  # Check if already published
  local published_version
  published_version=$(npm view "${name}@${version}" version 2>/dev/null || echo "")
  if [[ "$published_version" == "$version" ]]; then
    SKIPPED+=("$name@$version (already on npm)")
    return
  fi

  echo "  Publishing ${name}@${version} --tag ${TAG}..."

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    [DRY RUN] Would publish from ${pkg_dir}"
    PUBLISHED+=("$name@$version")
    return
  fi

  if (cd "$pkg_dir" && npm publish --tag "$TAG" --access public 2>&1); then
    PUBLISHED+=("$name@$version")
    echo "    OK ${name}@${version}"
  else
    FAILED+=("$name@$version")
    echo "    FAILED ${name}@${version}"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  Replace workspace:* references before publishing
# ═══════════════════════════════════════════════════════════════════════════
echo "Replacing workspace:* references..."
cd "$ELIZA_DIR"
if [[ -f "scripts/replace-workspace-versions.js" ]]; then
  node scripts/replace-workspace-versions.js || true
fi

# ═══════════════════════════════════════════════════════════════════════════
#  Publish packages in dependency order
# ═══════════════════════════════════════════════════════════════════════════

# Tier 1: Foundation packages (no deps on other @elizaos packages)
TIER1=(
  "packages/schemas"
  "packages/prompts"
  "packages/tui"
  "packages/skills"
  "packages/daemon"
)

# Tier 2: Core package
TIER2=(
  "packages/typescript"
)

# Tier 3: Packages depending on core
TIER3=(
  "packages/elizaos"
  "packages/interop"
  "packages/python"
  "packages/rust"
  "packages/sweagent"
)

# Tier 4: computeruse (depends on core + other packages)
TIER4=(
  "packages/computeruse/packages/computeruse-ts"
)

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Tier 1: Foundation packages"
echo "═══════════════════════════════════════════════════════════"
for dir in "${TIER1[@]}"; do
  full_dir="${ELIZA_DIR}/${dir}"
  if [[ -d "$full_dir" && -f "${full_dir}/package.json" ]]; then
    publish_pkg "$full_dir"
  fi
done

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Tier 2: @elizaos/core"
echo "═══════════════════════════════════════════════════════════"
for dir in "${TIER2[@]}"; do
  full_dir="${ELIZA_DIR}/${dir}"
  if [[ -d "$full_dir" && -f "${full_dir}/package.json" ]]; then
    publish_pkg "$full_dir"
  fi
done

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Tier 3: Packages depending on core"
echo "═══════════════════════════════════════════════════════════"
for dir in "${TIER3[@]}"; do
  full_dir="${ELIZA_DIR}/${dir}"
  if [[ -d "$full_dir" && -f "${full_dir}/package.json" ]]; then
    publish_pkg "$full_dir"
  fi
done

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Tier 4: computeruse"
echo "═══════════════════════════════════════════════════════════"
for dir in "${TIER4[@]}"; do
  full_dir="${ELIZA_DIR}/${dir}"
  if [[ -d "$full_dir" && -f "${full_dir}/package.json" ]]; then
    publish_pkg "$full_dir"
  fi
done

# ═══════════════════════════════════════════════════════════════════════════
#  Also publish any other packages we may have missed
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Remaining packages"
echo "═══════════════════════════════════════════════════════════"

# Collect already-processed dirs
PROCESSED=()
for arr in "${TIER1[@]}" "${TIER2[@]}" "${TIER3[@]}" "${TIER4[@]}"; do
  PROCESSED+=("$arr")
done

for dir in "${ELIZA_DIR}"/packages/*/; do
  if [[ -f "${dir}package.json" ]]; then
    rel_path="${dir#${ELIZA_DIR}/}"
    rel_path="${rel_path%/}"
    already_done=false
    for p in "${PROCESSED[@]}"; do
      if [[ "$rel_path" == "$p" ]]; then
        already_done=true
        break
      fi
    done
    if [[ "$already_done" == "false" ]]; then
      publish_pkg "$dir"
    fi
  fi
done

# ═══════════════════════════════════════════════════════════════════════════
#  Restore workspace:* references
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "Restoring workspace:* references..."
cd "$ELIZA_DIR"
if [[ -f "scripts/restore-workspace-refs.js" ]]; then
  node scripts/restore-workspace-refs.js || true
fi

# ═══════════════════════════════════════════════════════════════════════════
#  SUMMARY
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  PACKAGE PUBLISH SUMMARY"
echo "═══════════════════════════════════════════════════════════"
echo ""

pub_count=${#PUBLISHED[@]}
skip_count=${#SKIPPED[@]}
fail_count=${#FAILED[@]}

echo "  Published: ${pub_count}"
if [[ $pub_count -gt 0 ]]; then
  for p in "${PUBLISHED[@]}"; do echo "    + $p"; done
fi

echo ""
echo "  Skipped: ${skip_count}"
if [[ $skip_count -gt 0 ]]; then
  for s in "${SKIPPED[@]}"; do echo "    - $s"; done
fi

echo ""
if [[ $fail_count -gt 0 ]]; then
  echo "  FAILED: ${fail_count}"
  for f in "${FAILED[@]}"; do echo "    X $f"; done
  echo ""
  exit 1
else
  echo "  No failures!"
fi
echo ""
