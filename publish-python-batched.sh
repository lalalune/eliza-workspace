#!/usr/bin/env bash
# Batched PyPI publish - builds all packages, then uploads with rate-limit-aware batching
#
# Usage:
#   ./publish-python-batched.sh              # full publish
#   ./publish-python-batched.sh --build-only # build only, skip upload
#   ./publish-python-batched.sh --upload-only # upload pre-built dist dirs only

WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_DIR="${WORKSPACE_DIR}/plugins"
CORE_DIR="${WORKSPACE_DIR}/eliza/packages/python"
PYTHON="/opt/miniconda3/bin/python3"
if [[ ! -x "$PYTHON" ]]; then PYTHON="python3"; fi

BUILD_ONLY=false
UPLOAD_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --build-only) BUILD_ONLY=true ;;
    --upload-only) UPLOAD_ONLY=true ;;
  esac
done

# Delay between each upload (seconds) to avoid rate limits
UPLOAD_DELAY=20

PUBLISHED=()
SKIPPED=()
FAILED=()
BUILD_FAILED=()
DIST_DIRS=()

version_exists_on_pypi() {
  local pkg_name="$1"
  local pkg_version="$2"
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" "https://pypi.org/pypi/${pkg_name}/${pkg_version}/json")
  [[ "$status" == "200" ]]
}

get_pkg_info() {
  local toml_file="$1"
  $PYTHON -c "import tomllib; d=tomllib.load(open('${toml_file}','rb')); print(d['project']['name'] + '==' + d['project'].get('version',''))" 2>/dev/null || echo ""
}

# ═══════════════════════════════════════════════════════════
#  PHASE 1: Collect all package directories
# ═══════════════════════════════════════════════════════════
ALL_PKG_DIRS=()

# Core package first
if [[ -f "${CORE_DIR}/pyproject.toml" ]]; then
  ALL_PKG_DIRS+=("$CORE_DIR")
fi

# All plugins
for plugin_path in "${PLUGINS_DIR}"/plugin-*/python; do
  [[ -d "$plugin_path" && -f "${plugin_path}/pyproject.toml" ]] || continue
  ALL_PKG_DIRS+=("$plugin_path")
done

echo "Found ${#ALL_PKG_DIRS[@]} Python packages"
echo ""

# ═══════════════════════════════════════════════════════════
#  PHASE 2: Build all packages (skip already-on-PyPI)
# ═══════════════════════════════════════════════════════════
if [[ "$UPLOAD_ONLY" == "false" ]]; then
  echo "═══════════════════════════════════════════════════════════"
  echo "  Phase 1: Building all packages"
  echo "═══════════════════════════════════════════════════════════"
  echo ""

  for pkg_dir in "${ALL_PKG_DIRS[@]}"; do
    toml_file="${pkg_dir}/pyproject.toml"
    info=$(get_pkg_info "$toml_file")
    name="${info%%==*}"
    version="${info##*==}"

    if [[ -z "$name" || -z "$version" ]]; then
      echo "  SKIP: Could not parse ${toml_file}"
      continue
    fi

    if version_exists_on_pypi "$name" "$version"; then
      SKIPPED+=("${name}==${version} (already on PyPI)")
      echo "  SKIP: ${name}==${version} (already on PyPI)"
      continue
    fi

    echo "  BUILD: ${name}==${version}..."
    rm -rf "${pkg_dir}/dist" "${pkg_dir}/build" "${pkg_dir}"/*.egg-info

    if (cd "$pkg_dir" && $PYTHON -m build --no-isolation 2>&1 | tail -2); then
      if [[ -d "${pkg_dir}/dist" ]] && ls "${pkg_dir}/dist/"*.whl &>/dev/null; then
        echo "    OK built"
        DIST_DIRS+=("${pkg_dir}")
      else
        echo "    FAIL: no dist files"
        BUILD_FAILED+=("${name}==${version}")
      fi
    else
      echo "    FAIL: build error"
      BUILD_FAILED+=("${name}==${version}")
    fi
  done

  echo ""
  echo "Built ${#DIST_DIRS[@]} packages, ${#BUILD_FAILED[@]} build failures, ${#SKIPPED[@]} skipped"
  echo ""
else
  # Upload-only mode: find existing dist dirs
  for pkg_dir in "${ALL_PKG_DIRS[@]}"; do
    if [[ -d "${pkg_dir}/dist" ]] && ls "${pkg_dir}/dist/"*.whl &>/dev/null; then
      DIST_DIRS+=("${pkg_dir}")
    fi
  done
  echo "Found ${#DIST_DIRS[@]} pre-built packages to upload"
  echo ""
fi

if [[ "$BUILD_ONLY" == "true" ]]; then
  echo "Build-only mode, skipping upload."
  echo ""
  echo "  Packages ready: ${#DIST_DIRS[@]}"
  echo "  Build failures: ${#BUILD_FAILED[@]}"
  echo "  Skipped:        ${#SKIPPED[@]}"
  exit 0
fi

# ═══════════════════════════════════════════════════════════
#  PHASE 3: Upload packages one at a time with delays
# ═══════════════════════════════════════════════════════════
echo "═══════════════════════════════════════════════════════════"
echo "  Phase 2: Uploading ${#DIST_DIRS[@]} packages to PyPI"
echo "  (${UPLOAD_DELAY}s delay between uploads)"
echo "═══════════════════════════════════════════════════════════"
echo ""

upload_count=0

for pkg_dir in "${DIST_DIRS[@]}"; do
  toml_file="${pkg_dir}/pyproject.toml"
  info=$(get_pkg_info "$toml_file")
  name="${info%%==*}"
  version="${info##*==}"

  echo "  [$((upload_count + 1))/${#DIST_DIRS[@]}] Uploading ${name}==${version}..."

  local_output=$(twine upload "${pkg_dir}/dist/"* 2>&1) && local_exit=0 || local_exit=$?

  if [[ $local_exit -eq 0 ]]; then
    PUBLISHED+=("${name}==${version}")
    echo "    OK ${name}==${version}"
    upload_count=$((upload_count + 1))
    # Delay before next upload
    if [[ $upload_count -lt ${#DIST_DIRS[@]} ]]; then
      echo "    (waiting ${UPLOAD_DELAY}s before next upload...)"
      sleep "$UPLOAD_DELAY"
    fi
  elif echo "$local_output" | grep -q "429\|Too Many\|rate limit\|too many"; then
    echo "    RATE LIMITED - pausing 10 minutes before retry..."
    sleep 600
    # Retry once after long wait
    local_output=$(twine upload "${pkg_dir}/dist/"* 2>&1) && local_exit=0 || local_exit=$?
    if [[ $local_exit -eq 0 ]]; then
      PUBLISHED+=("${name}==${version}")
      echo "    OK (after retry) ${name}==${version}"
      upload_count=$((upload_count + 1))
      sleep "$UPLOAD_DELAY"
    else
      FAILED+=("${name}==${version}")
      echo "    UPLOAD FAILED ${name}==${version}"
      echo "    $local_output" | tail -3
    fi
  elif echo "$local_output" | grep -q "already exists\|File already exists"; then
    SKIPPED+=("${name}==${version} (already on PyPI)")
    echo "    Already exists, skipping"
  else
    FAILED+=("${name}==${version}")
    echo "    UPLOAD FAILED ${name}==${version}"
    echo "$local_output" | tail -3
  fi

  # Clean up dist after upload attempt
  rm -rf "${pkg_dir}/dist" "${pkg_dir}/build" "${pkg_dir}"/*.egg-info
done

# ═══════════════════════════════════════════════════════════
#  SUMMARY
# ═══════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  PYPI PUBLISH SUMMARY"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "  Published: ${#PUBLISHED[@]}"
for p in "${PUBLISHED[@]}"; do echo "    + $p"; done
echo ""
echo "  Skipped: ${#SKIPPED[@]}"
for s in "${SKIPPED[@]}"; do echo "    - $s"; done
echo ""
if [[ ${#BUILD_FAILED[@]} -gt 0 ]]; then
  echo "  Build Failures: ${#BUILD_FAILED[@]}"
  for bf in "${BUILD_FAILED[@]}"; do echo "    X $bf"; done
  echo ""
fi
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "  Upload Failures: ${#FAILED[@]}"
  for f in "${FAILED[@]}"; do echo "    X $f"; done
  exit 1
else
  echo "  No upload failures!"
fi
echo ""
