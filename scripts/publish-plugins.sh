#!/usr/bin/env bash
set -eo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# publish-plugins.sh — Publish all @elizaos plugins to npm
# ═══════════════════════════════════════════════════════════════════════════
#
# Publishes plugins from ./plugins/plugin-*/typescript/
# Respects dependency tiers (no inter-plugin deps first, then dependent ones).
#
# Usage:
#   scripts/publish-plugins.sh                  # full publish
#   scripts/publish-plugins.sh --dry-run        # show what would be published
#   scripts/publish-plugins.sh --tag next       # use a specific dist-tag (default: next)
#   scripts/publish-plugins.sh --version 2.0.0  # override version check

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGINS_DIR="${WORKSPACE_DIR}/plugins"

DRY_RUN=false
TAG="next"
TARGET_VERSION=""
FAILED=()
PUBLISHED=()
SKIPPED=()

# ── Parse arguments ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; shift ;;
    --tag)       TAG="$2"; shift 2 ;;
    --version)   TARGET_VERSION="$2"; shift 2 ;;
    *)           echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ "$DRY_RUN" == "true" ]]; then
  echo "=== DRY RUN MODE ==="
fi

echo ""
echo "Workspace:  ${WORKSPACE_DIR}"
echo "Plugins:    ${PLUGINS_DIR}"
echo "Tag:        ${TAG}"
[[ -n "$TARGET_VERSION" ]] && echo "Version:    ${TARGET_VERSION}"
echo ""

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
#  Categorize plugins by dependency tier
# ═══════════════════════════════════════════════════════════════════════════
TIER1_PLUGINS=()
TIER2_PLUGINS=()
TIER3_PLUGINS=()

for dir in "${PLUGINS_DIR}"/plugin-*/typescript; do
  if [[ -d "$dir" && -f "${dir}/package.json" ]]; then
    pkg_json="${dir}/package.json"

    has_computeruse_dep=$(node -e "
      const pkg = require('${pkg_json}');
      const deps = {...(pkg.dependencies||{}), ...(pkg.peerDependencies||{})};
      console.log(deps['@elizaos/computeruse'] ? 'yes' : 'no');
    ")

    has_plugin_dep=$(node -e "
      const pkg = require('${pkg_json}');
      const deps = {...(pkg.dependencies||{}), ...(pkg.peerDependencies||{})};
      const pluginDeps = Object.keys(deps).filter(d => d.startsWith('@elizaos/plugin-'));
      console.log(pluginDeps.length > 0 ? 'yes' : 'no');
    ")

    if [[ "$has_computeruse_dep" == "yes" ]]; then
      TIER3_PLUGINS+=("$dir")
    elif [[ "$has_plugin_dep" == "yes" ]]; then
      TIER2_PLUGINS+=("$dir")
    else
      TIER1_PLUGINS+=("$dir")
    fi
  fi
done

# ── Tier 1: no inter-plugin deps ──────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════"
echo "  Tier 1: ${#TIER1_PLUGINS[@]} plugins (no inter-plugin deps)"
echo "═══════════════════════════════════════════════════════════"
for dir in "${TIER1_PLUGINS[@]}"; do
  publish_pkg "$dir"
done

# ── Tier 2: depends on other plugins ──────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Tier 2: ${#TIER2_PLUGINS[@]} plugins (depend on other plugins)"
echo "═══════════════════════════════════════════════════════════"
for dir in "${TIER2_PLUGINS[@]}"; do
  publish_pkg "$dir"
done

# ── Tier 3: depends on computeruse ────────────────────────────────────────
if [[ ${#TIER3_PLUGINS[@]} -gt 0 ]]; then
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  Tier 3: ${#TIER3_PLUGINS[@]} plugins (computeruse-dependent)"
  echo "═══════════════════════════════════════════════════════════"
  for dir in "${TIER3_PLUGINS[@]}"; do
    publish_pkg "$dir"
  done
fi

# ═══════════════════════════════════════════════════════════════════════════
#  SUMMARY
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  PLUGIN PUBLISH SUMMARY"
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
