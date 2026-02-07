#!/usr/bin/env bash
set -eo pipefail

# Publish all elizaOS Python packages to PyPI
#
# Publishes in order:
#   1) Core package (elizaos)
#   2) All plugins (elizaos-plugin-*)
#
# Usage:
#   ./publish-python.sh              # full publish
#   ./publish-python.sh --dry-run    # dry run (build only, no upload)
#   ./publish-python.sh discord      # publish only plugin-discord
#
# Prerequisites:
#   - pip install twine build hatchling
#   - TWINE_USERNAME / TWINE_PASSWORD env vars set (or ~/.pypirc configured)
#     For token auth: TWINE_USERNAME=__token__ TWINE_PASSWORD=pypi-...

DRY_RUN=false
FILTER=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) FILTER="$arg" ;;
  esac
done

WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_DIR="${WORKSPACE_DIR}/plugins"
CORE_DIR="${WORKSPACE_DIR}/eliza/packages/python"

# Use miniconda python which has build/twine/hatchling installed
PYTHON="/opt/miniconda3/bin/python3"
if [[ ! -x "$PYTHON" ]]; then
  PYTHON="python3"
fi

PUBLISHED=()
SKIPPED=()
FAILED=()
BUILD_FAILED=()

# Use miniconda python which has build/hatchling/twine installed
PYTHON="/opt/miniconda3/bin/python3"
if [[ ! -x "$PYTHON" ]]; then
  PYTHON="python3"
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "=== DRY RUN MODE (build only, no upload) ==="
  echo ""
fi

# ── Helper: check if version exists on PyPI ──────────────────────────────
version_exists_on_pypi() {
  local pkg_name="$1"
  local pkg_version="$2"
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" "https://pypi.org/pypi/${pkg_name}/${pkg_version}/json")
  [[ "$status" == "200" ]]
}

# ── Helper: build and publish a single Python package ────────────────────
publish_py_pkg() {
  local pkg_dir="$1"
  local toml_file="${pkg_dir}/pyproject.toml"

  if [[ ! -f "$toml_file" ]]; then
    return
  fi

  local name version
  name=$($PYTHON -c "import tomllib; print(tomllib.load(open('${toml_file}','rb'))['project']['name'])" 2>/dev/null || echo "")
  version=$($PYTHON -c "import tomllib; print(tomllib.load(open('${toml_file}','rb'))['project'].get('version',''))" 2>/dev/null || echo "")

  if [[ -z "$name" || -z "$version" ]]; then
    echo "  SKIP: Could not parse name/version from ${toml_file}"
    return
  fi

  # Check if already on PyPI
  if version_exists_on_pypi "$name" "$version"; then
    SKIPPED+=("${name}==${version} (already on PyPI)")
    return
  fi

  echo "  Building ${name}==${version}..."

  # Clean previous builds
  rm -rf "${pkg_dir}/dist" "${pkg_dir}/build" "${pkg_dir}"/*.egg-info

  # Build
  if ! (cd "$pkg_dir" && $PYTHON -m build --no-isolation 2>&1 | tail -5); then
    echo "    BUILD FAILED for ${name}==${version}"
    BUILD_FAILED+=("${name}==${version}")
    return
  fi

  # Check that dist files were created
  if [[ ! -d "${pkg_dir}/dist" ]] || [[ -z "$(ls -A "${pkg_dir}/dist/" 2>/dev/null)" ]]; then
    echo "    BUILD FAILED: No dist files for ${name}"
    BUILD_FAILED+=("${name}==${version}")
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    [DRY RUN] Would upload: $(ls "${pkg_dir}/dist/")"
    PUBLISHED+=("${name}==${version}")
    rm -rf "${pkg_dir}/dist" "${pkg_dir}/build" "${pkg_dir}"/*.egg-info
    return
  fi

  # Upload to PyPI with retry logic for rate limits
  echo "  Uploading ${name}==${version}..."
  local max_retries=8
  local attempt=1
  local uploaded=false

  while [[ $attempt -le $max_retries ]]; do
    local output
    local exit_code
    output=$(twine upload "${pkg_dir}/dist/"* 2>&1) && exit_code=0 || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
      echo "$output" | tail -3
      PUBLISHED+=("${name}==${version}")
      echo "    OK ${name}==${version}"
      uploaded=true
      # Sleep between successful new project uploads to avoid rate limits
      sleep 20
      break
    elif echo "$output" | grep -q "429\|Too Many\|rate limit\|too many"; then
      # Exponential backoff: 60, 120, 240, 480, 600, 600, 600, 600
      local wait_time=$((60 * (2 ** (attempt - 1))))
      if [[ $wait_time -gt 600 ]]; then wait_time=600; fi
      echo "    Rate limited (attempt ${attempt}/${max_retries}), waiting ${wait_time}s..."
      sleep "$wait_time"
      attempt=$((attempt + 1))
    elif echo "$output" | grep -q "already exists"; then
      echo "    Already exists on PyPI, skipping"
      SKIPPED+=("${name}==${version} (already on PyPI)")
      uploaded=true
      break
    else
      echo "$output" | tail -5
      FAILED+=("${name}==${version}")
      echo "    UPLOAD FAILED ${name}==${version}"
      break
    fi
  done

  if [[ "$uploaded" == "false" && $attempt -gt $max_retries ]]; then
    FAILED+=("${name}==${version} (rate limited after ${max_retries} retries)")
    echo "    UPLOAD FAILED (exhausted retries) ${name}==${version}"
  fi

  # Clean up dist
  rm -rf "${pkg_dir}/dist" "${pkg_dir}/build" "${pkg_dir}"/*.egg-info
}

# ══════════════════════════════════════════════════════════════════════════
#  WAVE 1: Core package (elizaos)
# ══════════════════════════════════════════════════════════════════════════
if [[ -z "$FILTER" ]]; then
  echo "═══════════════════════════════════════════════════════════"
  echo "  Wave 1: Core package (elizaos)"
  echo "═══════════════════════════════════════════════════════════"
  echo ""

  if [[ -d "$CORE_DIR" && -f "${CORE_DIR}/pyproject.toml" ]]; then
    publish_py_pkg "$CORE_DIR"
  fi
  echo ""
fi

# ══════════════════════════════════════════════════════════════════════════
#  WAVE 2: All plugins
# ══════════════════════════════════════════════════════════════════════════
echo "═══════════════════════════════════════════════════════════"
echo "  Wave 2: Publishing plugins to PyPI"
echo "═══════════════════════════════════════════════════════════"
echo ""

for plugin_path in "${PLUGINS_DIR}"/plugin-*/python; do
  [[ -d "$plugin_path" ]] || continue
  [[ -f "${plugin_path}/pyproject.toml" ]] || continue

  dirname="$(basename "$(dirname "$plugin_path")")"

  # If filter is set, skip non-matching plugins
  if [[ -n "$FILTER" && "$dirname" != "plugin-${FILTER}" ]]; then
    continue
  fi

  publish_py_pkg "$plugin_path"
done

# ══════════════════════════════════════════════════════════════════════════
#  SUMMARY
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  PYPI PUBLISH SUMMARY"
echo "═══════════════════════════════════════════════════════════"
echo ""

pub_count=${#PUBLISHED[@]}
skip_count=${#SKIPPED[@]}
fail_count=${#FAILED[@]}
build_fail_count=${#BUILD_FAILED[@]}

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
if [[ $build_fail_count -gt 0 ]]; then
  echo "  Build Failures: ${build_fail_count}"
  for bf in "${BUILD_FAILED[@]}"; do
    echo "    X $bf"
  done
  echo ""
fi

if [[ $fail_count -gt 0 ]]; then
  echo "  Upload Failures: ${fail_count}"
  for f in "${FAILED[@]}"; do
    echo "    X $f"
  done
  echo ""
  exit 1
else
  echo "  No upload failures!"
fi
echo ""
