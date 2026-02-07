#!/usr/bin/env bash
set -eo pipefail

# Ordered publish script: publishes alpha versions with --tag next
# Handles split-repo layout:
#   Plugins:  ./plugins/*/typescript/         (eliza-workspace)
#   Packages: ../eliza-ok/packages/           (eliza-ok)
#
# Order: 1) plugins  2) packages (except computeruse)  3) computeruse
#
# Usage:
#   ./publish-ordered.sh           # full publish
#   ./publish-ordered.sh --dry-run # dry run (shows what would be published)

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "=== DRY RUN MODE ==="
fi

WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELIZA_OK_DIR="${WORKSPACE_DIR}/eliza"
TAG="next"
TARGET_VERSION="2.0.0-alpha.4"
FAILED=()
PUBLISHED=()
SKIPPED=()

echo ""
echo "Workspace:  ${WORKSPACE_DIR}"
echo "Eliza repo: ${ELIZA_OK_DIR}"
echo "Version:    ${TARGET_VERSION}"
echo "Tag:        ${TAG}"
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

# ══════════════════════════════════════════════════════════════════════════
#  WAVE 1: Publish ALL plugins
# ══════════════════════════════════════════════════════════════════════════
echo "═══════════════════════════════════════════════════════════"
echo "  Wave 1: Publishing plugins (--tag ${TAG})"
echo "═══════════════════════════════════════════════════════════"

# Categorize plugins by dependency tier
TIER1_PLUGINS=()
TIER2_PLUGINS=()
TIER3_PLUGINS=()

for dir in "${WORKSPACE_DIR}"/plugins/plugin-*/typescript; do
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

# Tier 1: no inter-plugin deps
echo ""
echo "  Tier 1: ${#TIER1_PLUGINS[@]} plugins (no inter-plugin deps)"
for dir in "${TIER1_PLUGINS[@]}"; do
  publish_pkg "$dir"
done

# Tier 2: depends on other plugins
echo ""
echo "  Tier 2: ${#TIER2_PLUGINS[@]} plugins (depend on other plugins)"
for dir in "${TIER2_PLUGINS[@]}"; do
  publish_pkg "$dir"
done

# ══════════════════════════════════════════════════════════════════════════
#  WAVE 2: Publish packages (except computeruse)
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Wave 2: Publishing packages (--tag ${TAG})"
echo "═══════════════════════════════════════════════════════════"

# Replace workspace:* refs in eliza-ok packages
echo ""
echo "  Replacing workspace:* references in packages..."
cd "$ELIZA_OK_DIR"
if [[ -f "scripts/replace-workspace-versions.js" ]]; then
  node scripts/replace-workspace-versions.js || true
fi

WAVE2_TIER1=(
  "packages/schemas"
  "packages/prompts"
  "packages/tui"
  "packages/skills"
  "packages/daemon"
)
WAVE2_TIER2=(
  "packages/typescript"
)
WAVE2_TIER3=(
  "packages/elizaos"
  "packages/interop"
  "packages/python"
  "packages/rust"
  "packages/sweagent"
)

echo ""
echo "  Tier 1: Foundation packages"
for dir in "${WAVE2_TIER1[@]}"; do
  full_dir="${ELIZA_OK_DIR}/${dir}"
  if [[ -d "$full_dir" && -f "${full_dir}/package.json" ]]; then
    publish_pkg "$full_dir"
  fi
done

echo ""
echo "  Tier 2: @elizaos/core"
for dir in "${WAVE2_TIER2[@]}"; do
  full_dir="${ELIZA_OK_DIR}/${dir}"
  if [[ -d "$full_dir" && -f "${full_dir}/package.json" ]]; then
    publish_pkg "$full_dir"
  fi
done

echo ""
echo "  Tier 3: Packages depending on core"
for dir in "${WAVE2_TIER3[@]}"; do
  full_dir="${ELIZA_OK_DIR}/${dir}"
  if [[ -d "$full_dir" && -f "${full_dir}/package.json" ]]; then
    publish_pkg "$full_dir"
  fi
done

# Restore workspace:* refs
echo ""
echo "  Restoring workspace:* references in packages..."
cd "$ELIZA_OK_DIR"
if [[ -f "scripts/restore-workspace-refs.js" ]]; then
  node scripts/restore-workspace-refs.js || true
fi

# ══════════════════════════════════════════════════════════════════════════
#  WAVE 3: Publish computeruse + computeruse-dependent plugins
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Wave 3: Publishing computeruse (--tag ${TAG})"
echo "═══════════════════════════════════════════════════════════"

CU_TS_DIR="${ELIZA_OK_DIR}/packages/computeruse/packages/computeruse-ts"
if [[ -d "$CU_TS_DIR" && -f "${CU_TS_DIR}/package.json" ]]; then
  publish_pkg "$CU_TS_DIR"
fi

echo ""
echo "  Tier 3 plugins: ${#TIER3_PLUGINS[@]} computeruse-dependent plugins"
for dir in "${TIER3_PLUGINS[@]}"; do
  publish_pkg "$dir"
done

# ══════════════════════════════════════════════════════════════════════════
#  Ensure "next" dist-tag is set on all packages
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Ensuring 'next' dist-tag on all @elizaos packages"
echo "═══════════════════════════════════════════════════════════"
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

  # Check current "next" tag
  local current_next
  current_next=$(npm dist-tag ls "$name" 2>/dev/null | grep "^next:" | awk '{print $2}' || echo "")

  if [[ "$current_next" != "$version" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  [DRY RUN] Would tag ${name}@${version} as next (currently: ${current_next:-none})"
    else
      if npm dist-tag add "${name}@${version}" next 2>/dev/null; then
        echo "  Tagged ${name}@${version} as next"
      else
        echo "  Could not tag ${name}@${version} (may not be on npm yet)"
      fi
    fi
  fi
}

# Tag all plugins
for dir in "${WORKSPACE_DIR}"/plugins/plugin-*/typescript; do
  if [[ -d "$dir" && -f "${dir}/package.json" ]]; then
    tag_package "$dir"
  fi
done

# Tag all packages
for dir in "${ELIZA_OK_DIR}"/packages/*/; do
  if [[ -f "${dir}package.json" ]]; then
    tag_package "$dir"
  fi
done

# Tag computeruse
if [[ -d "$CU_TS_DIR" && -f "${CU_TS_DIR}/package.json" ]]; then
  tag_package "$CU_TS_DIR"
fi

# ══════════════════════════════════════════════════════════════════════════
#  SUMMARY
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  PUBLISH SUMMARY"
echo "═══════════════════════════════════════════════════════════"
echo ""

pub_count=${#PUBLISHED[@]}
skip_count=${#SKIPPED[@]}
fail_count=${#FAILED[@]}

echo "  Published: ${pub_count}"
if [[ $pub_count -gt 0 ]]; then
  for p in "${PUBLISHED[@]}"; do
    echo "    + $p"
  done
fi

echo ""
echo "  Skipped: ${skip_count}"
if [[ $skip_count -gt 0 ]]; then
  for s in "${SKIPPED[@]}"; do
    echo "    - $s"
  done
fi

echo ""
if [[ $fail_count -gt 0 ]]; then
  echo "  FAILED: ${fail_count}"
  for f in "${FAILED[@]}"; do
    echo "    X $f"
  done
  echo ""
  exit 1
else
  echo "  No failures!"
fi
echo ""
