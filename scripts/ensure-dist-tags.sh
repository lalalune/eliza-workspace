#!/usr/bin/env bash
set -eo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# ensure-dist-tags.sh — Ensure dist-tags are correct on npm
# ═══════════════════════════════════════════════════════════════════════════
#
# Verifies that the 'next' (or specified) dist-tag points to the correct
# version for all @elizaos packages and plugins.
#
# Usage:
#   scripts/ensure-dist-tags.sh                  # check & fix tags
#   scripts/ensure-dist-tags.sh --dry-run        # show what would change
#   scripts/ensure-dist-tags.sh --tag next       # specify tag (default: next)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ELIZA_DIR="${WORKSPACE_DIR}/eliza"
PLUGINS_DIR="${WORKSPACE_DIR}/plugins"

DRY_RUN=false
TAG="next"

# ── Parse arguments ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; shift ;;
    --tag)       TAG="$2"; shift 2 ;;
    *)           shift ;;
  esac
done

echo "Ensuring '${TAG}' dist-tag on all @elizaos packages..."
echo ""

tag_package() {
  local pkg_dir="$1"
  local pkg_json="${pkg_dir}/package.json"
  if [[ ! -f "$pkg_json" ]]; then return; fi

  local name version private_field
  name=$(node -e "console.log(require('${pkg_json}').name || '')")
  version=$(node -e "console.log(require('${pkg_json}').version || '')")
  private_field=$(node -e "console.log(require('${pkg_json}').private === true ? 'true' : 'false')")

  if [[ -z "$name" || -z "$version" || "$private_field" == "true" ]]; then return; fi

  local current_tag
  current_tag=$(npm dist-tag ls "$name" 2>/dev/null | grep "^${TAG}:" | awk '{print $2}' || echo "")

  if [[ "$current_tag" != "$version" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  [DRY RUN] Would tag ${name}@${version} as ${TAG} (currently: ${current_tag:-none})"
    else
      if npm dist-tag add "${name}@${version}" "${TAG}" 2>/dev/null; then
        echo "  Tagged ${name}@${version} as ${TAG}"
      else
        echo "  Could not tag ${name}@${version} (may not be on npm yet)"
      fi
    fi
  fi
}

# Tag all plugins
for dir in "${PLUGINS_DIR}"/plugin-*/typescript; do
  if [[ -d "$dir" && -f "${dir}/package.json" ]]; then
    tag_package "$dir"
  fi
done

# Tag all packages
if [[ -d "$ELIZA_DIR/packages" ]]; then
  for dir in "${ELIZA_DIR}"/packages/*/; do
    if [[ -f "${dir}package.json" ]]; then
      tag_package "$dir"
    fi
  done
fi

# Tag computeruse
CU_TS_DIR="${ELIZA_DIR}/packages/computeruse/packages/computeruse-ts"
if [[ -d "$CU_TS_DIR" && -f "${CU_TS_DIR}/package.json" ]]; then
  tag_package "$CU_TS_DIR"
fi

echo ""
echo "Dist-tag verification complete."
