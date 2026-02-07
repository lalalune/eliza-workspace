# Publishing Guide — elizaOS

This document covers how to publish **Rust crates** to [crates.io](https://crates.io) and **Python packages** to [PyPI](https://pypi.org) for the elizaOS ecosystem.

> **See also:** NPM publishing is handled by `publish-ordered.sh` and the `release.yaml` workflow. This guide focuses on Rust and Python only.

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Rust — Publishing to crates.io](#rust--publishing-to-cratesio)
  - [One-Time Setup](#rust-one-time-setup)
  - [Package Inventory](#rust-package-inventory)
  - [Publishing Order](#rust-publishing-order)
  - [Manual Publishing (Single Crate)](#rust-manual-publishing-single-crate)
  - [Batch Publishing (All Crates)](#rust-batch-publishing-all-crates)
  - [CI/CD (GitHub Actions)](#rust-cicd-github-actions)
  - [WASM Builds](#wasm-builds)
  - [Troubleshooting](#rust-troubleshooting)
- [Python — Publishing to PyPI](#python--publishing-to-pypi)
  - [One-Time Setup](#python-one-time-setup)
  - [Package Inventory](#python-package-inventory)
  - [Publishing Order](#python-publishing-order)
  - [Manual Publishing (Single Package)](#python-manual-publishing-single-package)
  - [Batch Publishing (All Packages)](#python-batch-publishing-all-packages)
  - [CI/CD (GitHub Actions)](#python-cicd-github-actions)
  - [Maturin Packages (Rust + Python)](#maturin-packages-rust--python)
  - [Troubleshooting](#python-troubleshooting)
- [Coordinated Releases](#coordinated-releases)
- [Version Management](#version-management)
- [GitHub Secrets Reference](#github-secrets-reference)

---

## Overview

The elizaOS workspace publishes packages to three registries:

| Registry | Language | Packages | Script | Workflow |
|----------|----------|----------|--------|----------|
| [crates.io](https://crates.io) | Rust | ~93 crates | `publish-rust.sh` | `release-rust.yaml` |
| [PyPI](https://pypi.org) | Python | ~93 packages | `publish-python.sh` | `release-python.yaml` |
| [npm](https://npmjs.com) | TypeScript | ~100 packages | `publish-ordered.sh` | `release.yaml` |

### Workspace Layout

```
eliza-workspace/
├── eliza/                        # Core monorepo (submodule)
│   ├── packages/
│   │   ├── rust/                 # elizaos (core Rust crate)
│   │   ├── python/               # elizaos (core Python package)
│   │   ├── sweagent/
│   │   │   ├── rust/             # elizaos-sweagent (Rust)
│   │   │   └── python/           # sweagent (Python)
│   │   └── computeruse/
│   │       └── packages/
│   │           └── computeruse-python/  # computeruse-py (maturin/PyO3)
│   └── .github/workflows/
│       ├── release-rust.yaml
│       └── release-python.yaml
├── plugins/
│   └── plugin-*/
│       ├── rust/                 # elizaos-plugin-* (Rust crate)
│       └── python/               # elizaos-plugin-* (Python package)
├── publish-rust.sh               # Local Rust publishing script
├── publish-python.sh             # Local Python publishing script
└── publish-ordered.sh            # Local NPM publishing script
```

---

## Prerequisites

### Tools Required

```bash
# Rust toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup component add rustfmt clippy
rustup target add wasm32-unknown-unknown   # for WASM builds
cargo install wasm-pack                     # for WASM packaging

# Python toolchain
python3 -m pip install --upgrade pip
pip install build twine hatchling

# Verify installations
cargo --version    # 1.75+
rustfmt --version
python3 --version  # 3.11+
twine --version
```

---

## Rust — Publishing to crates.io

### Rust One-Time Setup

#### 1. Create a crates.io Account

1. Go to [crates.io](https://crates.io)
2. Click **"Log in with GitHub"** in the top-right
3. Authorize crates.io to access your GitHub account

#### 2. Generate an API Token

1. Go to [crates.io/settings/tokens](https://crates.io/settings/tokens)
2. Click **"New Token"**
3. Name it something descriptive (e.g., `elizaos-publish`)
4. Select scopes:
   - **publish-new** — Publish new crates
   - **publish-update** — Update existing crates
5. Click **"Generate Token"**
6. **Copy the token immediately** — you won't see it again

#### 3. Authenticate Locally

```bash
# Option A: Login interactively (stores token in ~/.cargo/credentials.toml)
cargo login <YOUR_TOKEN>

# Option B: Use environment variable (for scripts/CI)
export CARGO_REGISTRY_TOKEN=<YOUR_TOKEN>
```

#### 4. Verify Ownership

To publish `elizaos-*` crates, you must be an owner or team member. Check ownership:

```bash
# Check who owns a crate
cargo owner --list elizaos

# Add a new owner (requires existing owner)
cargo owner --add <github-username> elizaos
cargo owner --add github:elizaos:publishers elizaos
```

> **Important:** The first time a crate is published, the person running `cargo publish` becomes the owner. For subsequent publishes, they must grant ownership to others or a GitHub team.

#### 5. Crate Name Reservation

New crates are automatically claimed on first publish. If you need to reserve a name without publishing code:

```bash
# There's no official reservation mechanism — you must publish at least once.
# Use cargo publish --dry-run to verify the name is available:
cargo publish --dry-run
```

### Rust Package Inventory

#### Core Packages (in `eliza/packages/`)

| Crate | Path | Features | WASM |
|-------|------|----------|------|
| `elizaos` | `eliza/packages/rust/` | `native`, `wasm`, `bootstrap`, `sync`, `icp` | Yes |
| `elizaos-sweagent` | `eliza/packages/sweagent/rust/` | `native`, `wasm` | No |

#### Plugin Packages (in `plugins/plugin-*/rust/`)

There are **91 plugin crates**, all following the naming pattern `elizaos-plugin-{name}`.

**Plugins with `elizaos` dependency** (13 crates — must publish after core):
`plugin-sql`, `plugin-openai`, `plugin-goals`, `plugin-localdb`, `plugin-todo`, `plugin-xai`, `plugin-discord`, `plugin-bluebubbles`, `plugin-copilot-proxy`, `plugin-rlm`, `plugin-whatsapp`, `plugin-acp`, `plugin-scratchpad`

**Independent plugins** (78 crates — no core dependency):
All other plugins, including `plugin-anthropic`, `plugin-telegram`, `plugin-solana`, `plugin-slack`, etc.

### Rust Publishing Order

Crates must be published in dependency order because crates.io resolves dependencies at publish time:

```
Wave 1: elizaos                    (core — must go first)
Wave 2: elizaos-sweagent           (independent — parallel-safe)
         ↓ wait ~2 min for crates.io indexing
Wave 3: 13 dependent plugins       (depend on elizaos)
Wave 4: 78 independent plugins     (no elizaos dep — all parallel-safe)
```

> **Why the wait?** After publishing `elizaos`, crates.io needs ~2 minutes to index the new version. Dependent crates will fail to resolve the dependency if published too quickly.

### Rust Manual Publishing (Single Crate)

#### Publishing the Core Crate

```bash
cd eliza/packages/rust

# 1. Verify formatting and lint
cargo fmt --all -- --check
cargo clippy --features native -- -D warnings

# 2. Run tests
cargo test --features native

# 3. Build release
cargo build --release --features native

# 4. Dry-run publish (verifies everything without uploading)
cargo publish --dry-run

# 5. Publish for real
cargo publish
```

#### Publishing a Plugin Crate

```bash
cd plugins/plugin-telegram/rust

# 1. Verify formatting and lint
cargo fmt --all -- --check
cargo clippy -- -D warnings

# 2. Run tests
cargo test

# 3. Dry-run publish
cargo publish --dry-run

# 4. Publish
cargo publish
```

#### Publishing a Dependent Plugin

For plugins that depend on `elizaos` via a path reference, you must rewrite the dependency before publishing:

```bash
cd plugins/plugin-openai/rust

# The Cargo.toml may have:
#   elizaos = { version = "2.0.0", path = "../../../eliza/packages/rust" }
#
# For publishing, this must become:
#   elizaos = "2.0.0"

# 1. Update dependency (replace path with version-only)
sed -i 's|elizaos = { version = "[^"]*", path = "[^"]*"[^}]*}|elizaos = "2.0.0"|' Cargo.toml

# 2. Verify it builds with the published dependency
cargo build --release

# 3. Publish
cargo publish --allow-dirty

# 4. Restore the path dependency (for local development)
git checkout Cargo.toml
```

### Rust Batch Publishing (All Crates)

Use the `publish-rust.sh` script to publish all crates in the correct order:

```bash
# Full publish to crates.io
./publish-rust.sh

# Dry run — verify everything is publishable without uploading
./publish-rust.sh --dry-run

# Check only — run fmt, clippy, and tests (no publish)
./publish-rust.sh --check

# Override version for all crates
./publish-rust.sh --version 2.1.0

# Customize wait time for crates.io indexing (default: 120s)
./publish-rust.sh --wait 180
```

The script:
1. Publishes `elizaos` (core) first
2. Publishes `elizaos-sweagent` (independent)
3. Waits for crates.io to index `elizaos`
4. Publishes 13 dependent plugins
5. Publishes 78 independent plugins
6. Reports a summary of published/skipped/failed crates

### Rust CI/CD (GitHub Actions)

The `release-rust.yaml` workflow handles automated publishing.

**Triggers:**
- **GitHub Release** — publishes all crates on release creation
- **Manual dispatch** — publish a specific crate or all crates

**To trigger manually:**

1. Go to **Actions** → **Rust Release**
2. Click **"Run workflow"**
3. Select a specific crate or `all`
4. Optionally enable dry-run mode
5. Click **"Run workflow"**

**What the workflow does:**

1. Builds and publishes `elizaos` (with WASM artifacts)
2. In parallel: builds `elizaos-sweagent`
3. Waits 120s for crates.io indexing
4. Builds and publishes `elizaos-plugin-sql` (with WASM)
5. Builds and publishes 12 dependent plugins (matrix, parallel)
6. Builds and publishes 78 independent plugins (matrix, parallel)
7. Generates release summary

**Required secret:** `CRATES_IO_TOKEN`

### WASM Builds

Some crates support WebAssembly targets. These are built automatically during CI.

```bash
cd eliza/packages/rust

# Build for browser/bundler
wasm-pack build --target web --out-dir pkg/web --features wasm --no-default-features

# Build for Node.js
wasm-pack build --target nodejs --out-dir pkg/node --features wasm --no-default-features
```

WASM artifacts are uploaded to the GitHub Release as tarballs:
- `elizaos-wasm-web.tar.gz` — Browser/bundler target
- `elizaos-wasm-node.tar.gz` — Node.js target
- `elizaos-plugin-sql-wasm-web.tar.gz` — SQL plugin browser target
- `elizaos-plugin-sql-wasm-node.tar.gz` — SQL plugin Node.js target

### Rust Troubleshooting

#### "crate `elizaos` not found" when publishing a dependent plugin

The core crate hasn't been indexed by crates.io yet. Wait 2–3 minutes after publishing `elizaos`, then retry.

```bash
# Check if elizaos is indexed
cargo search elizaos --limit 1
```

#### "this crate has been published by another user"

You don't have ownership of the crate. Ask an existing owner to add you:

```bash
cargo owner --add <your-github-username> <crate-name>
```

#### "failed to verify package tarball"

Usually caused by path dependencies. Ensure all `path = "..."` references are removed or that `--allow-dirty` is used:

```bash
cargo publish --allow-dirty
```

#### "package is too large"

Check your `include` field in `Cargo.toml`. Only include source code, not build artifacts:

```toml
[package]
include = ["src/**/*", "Cargo.toml", "README.md", "LICENSE"]
```

#### Version already published

crates.io does not allow overwriting published versions. You must bump the version:

```bash
# Check what's already published
cargo search elizaos-plugin-telegram
```

#### Rate limiting

crates.io rate-limits publishes. If publishing many crates at once, add delays between them. The `publish-rust.sh` script handles this automatically.

---

## Python — Publishing to PyPI

### Python One-Time Setup

#### 1. Create a PyPI Account

1. Go to [pypi.org/account/register/](https://pypi.org/account/register/)
2. Create an account and **verify your email**
3. **Enable 2FA** (required for publishing since 2024)

#### 2. Generate an API Token

1. Go to [pypi.org/manage/account/token/](https://pypi.org/manage/account/token/)
2. Click **"Add API token"**
3. Token name: `elizaos-publish`
4. Scope: **"Entire account"** (for publishing new packages) or a specific project
5. Click **"Add token"**
6. **Copy the token immediately** — it starts with `pypi-` and you won't see it again

#### 3. Configure Locally

```bash
# Option A: Configure twine (create/edit ~/.pypirc)
cat > ~/.pypirc << 'EOF'
[distutils]
index-servers = pypi

[pypi]
username = __token__
password = pypi-YOUR_TOKEN_HERE
EOF
chmod 600 ~/.pypirc

# Option B: Use environment variables (for scripts/CI)
export TWINE_USERNAME=__token__
export TWINE_PASSWORD=pypi-YOUR_TOKEN_HERE
```

#### 4. Test with TestPyPI (Optional but Recommended)

Before publishing to production PyPI, test with [test.pypi.org](https://test.pypi.org):

1. Create an account at [test.pypi.org/account/register/](https://test.pypi.org/account/register/)
2. Generate a token at [test.pypi.org/manage/account/token/](https://test.pypi.org/manage/account/token/)
3. Publish to TestPyPI:

```bash
twine upload --repository testpypi dist/*
```

4. Test installation:

```bash
pip install --index-url https://test.pypi.org/simple/ elizaos
```

#### 5. Package Name Ownership

PyPI package names are first-come-first-served. Once you publish a package, you are the owner. To add collaborators:

1. Go to `pypi.org/manage/project/<package-name>/collaboration/`
2. Add collaborators by PyPI username with **"Maintainer"** or **"Owner"** role

### Python Package Inventory

#### Core Packages

| Package | Path | Build System | Version |
|---------|------|-------------|---------|
| `elizaos` | `eliza/packages/python/` | hatchling | 2.0.0a4 |
| `sweagent` | `eliza/packages/sweagent/python/` | setuptools | dynamic |
| `computeruse-py` | `eliza/packages/computeruse/packages/computeruse-python/` | maturin (Rust+Python) | dynamic |

#### Plugin Packages (in `plugins/plugin-*/python/`)

There are **~90 plugin packages**, all following the naming pattern `elizaos-plugin-{name}`.

- **Build system:** Most use `hatchling`; a few use `setuptools`
- **Version:** `2.0.0a4` (alpha, PEP 440 format)
- **All are pure Python** (no compiled extensions), except `computeruse-py`

### Python Publishing Order

Python packages have simpler dependency management than Rust (pip resolves lazily), but order still matters:

```
Wave 1: elizaos             (core — publish first)
Wave 2: All plugins          (depend on elizaos at runtime)
Wave 3: computeruse-py       (special — requires maturin + Rust toolchain)
```

### Python Manual Publishing (Single Package)

#### Publishing the Core Package

```bash
cd eliza/packages/python

# 1. Install build tools
pip install build twine

# 2. Clean previous builds
rm -rf dist/ build/ *.egg-info

# 3. Build the package (creates sdist + wheel)
python -m build

# 4. Verify the package
twine check dist/*

# 5. Dry-run: upload to TestPyPI
twine upload --repository testpypi dist/*

# 6. Publish to production PyPI
twine upload dist/*
```

#### Publishing a Plugin Package

```bash
cd plugins/plugin-telegram/python

# 1. Clean and build
rm -rf dist/ build/ *.egg-info
python -m build

# 2. Verify
twine check dist/*

# 3. Publish
twine upload dist/*
```

#### Updating Versions

Use the version management script to update all Python packages at once:

```bash
cd eliza

# Update all Python packages to a specific version
python scripts/update-python-versions.py 2.0.0

# For alpha releases (auto-converts to PEP 440: 2.0.0a5)
python scripts/update-python-versions.py 2.0.0-alpha.5
```

This script updates:
- `version` field in all `pyproject.toml` files
- `__version__` in `__init__.py` files
- Dependency version constraints

### Python Batch Publishing (All Packages)

Use the `publish-python.sh` script:

```bash
# Full publish to PyPI
./publish-python.sh

# Dry run — build and verify without uploading
./publish-python.sh --dry-run

# Publish a specific plugin only
./publish-python.sh plugin-telegram
```

### Python CI/CD (GitHub Actions)

The `release-python.yaml` workflow handles automated publishing.

**Triggers:**
- **GitHub Release** — publishes all packages on release creation
- **Manual dispatch** — publish a specific package or all

**To trigger manually:**

1. Go to **Actions** → **Python Release**
2. Click **"Run workflow"**
3. Enter a package name (or leave as `all`)
4. Optionally enable dry-run mode
5. Click **"Run workflow"**

**What the workflow does:**

1. Dynamically discovers all Python packages (core + plugins)
2. Extracts version from the release tag
3. Updates all versions using `scripts/update-python-versions.py`
4. For each package (matrix, parallel):
   - Installs dependencies
   - Runs tests (`pytest`)
   - Builds with `python -m build`
   - Verifies with `twine check`
   - Publishes with `twine upload`
5. Generates per-package summary

**Required secret:** `PYPI_TOKEN`

### Maturin Packages (Rust + Python)

The `computeruse-py` package uses [maturin](https://www.maturin.rs/) to build Python wheels from Rust code via PyO3.

#### Building Locally

```bash
cd eliza/packages/computeruse/packages/computeruse-python

# Install maturin
pip install maturin

# Build a wheel for your current platform
maturin build --release

# Build and install directly
maturin develop --release

# Build for all platforms (requires cross-compilation setup)
maturin build --release --target x86_64-unknown-linux-gnu
maturin build --release --target aarch64-apple-darwin
```

#### CI Publishing

The `ci-wheels.yml` workflow builds wheels for multiple platforms:
- Linux: x86_64, aarch64
- macOS: x86_64, aarch64 (Apple Silicon)
- Windows: x86_64, aarch64

It uses `pypa/gh-action-pypi-publish` for trusted publishing to PyPI.

### Python Troubleshooting

#### "403 Forbidden" when uploading

Your API token doesn't have permission for this package. Either:
- Use an account-scoped token, or
- Ask the package owner to add you as a collaborator at `pypi.org/manage/project/<name>/collaboration/`

#### "File already exists" (409 Conflict)

PyPI does not allow overwriting published versions. Bump the version number:

```bash
# Check what's published
pip index versions elizaos-plugin-telegram
```

#### "Invalid version" 

PyPI requires [PEP 440](https://peps.python.org/pep-0440/) version strings:

| Invalid | Valid PEP 440 |
|---------|--------------|
| `2.0.0-alpha.1` | `2.0.0a1` |
| `2.0.0-beta.2` | `2.0.0b2` |
| `2.0.0-rc.1` | `2.0.0rc1` |

The `update-python-versions.py` script handles this conversion automatically.

#### "No module named 'build'" 

```bash
pip install build twine hatchling
```

#### Package not found after publishing

PyPI can take a few minutes to update its index. Wait and retry:

```bash
pip install --no-cache-dir elizaos-plugin-telegram
```

---

## Coordinated Releases

When doing a full release across all three registries, follow this order:

### Step-by-Step Release Process

```
1. Update versions across all languages
   ├── TypeScript: update package.json files
   ├── Rust:       update Cargo.toml files
   └── Python:     run scripts/update-python-versions.py

2. Create a GitHub Release (tag: v2.x.x)
   └── This triggers all three workflows automatically

3. Automated workflow execution order:
   ├── release.yaml         → NPM packages (TypeScript)
   ├── release-rust.yaml    → crates.io (Rust)
   └── release-python.yaml  → PyPI (Python)

4. Verify all packages are published:
   ├── npm view @elizaos/core version
   ├── cargo search elizaos --limit 1
   └── pip index versions elizaos
```

### Manual Coordinated Release

If you need to publish manually (e.g., CI is down):

```bash
# 1. Rust first (other languages may depend on Rust via FFI/WASM)
./publish-rust.sh --version 2.1.0

# 2. Python next
./publish-python.sh

# 3. TypeScript/NPM last
./publish-ordered.sh
```

---

## Version Management

### Current Version Scheme

| Language | Format | Example |
|----------|--------|---------|
| Rust | semver | `2.0.0` |
| Python | PEP 440 | `2.0.0a4` (alpha), `2.0.0` (stable) |
| TypeScript | semver | `2.0.0-alpha.4` |

### Bumping Versions

#### Rust (all crates)

```bash
# Update all plugin Cargo.toml files
cd eliza-workspace
find plugins/*/rust/Cargo.toml -exec \
  perl -i -pe 's/^version\s*=\s*"[^"]*"/version = "2.1.0"/' {} \;

# Update core crates
perl -i -pe 's/^version\s*=\s*"[^"]*"/version = "2.1.0"/' \
  eliza/packages/rust/Cargo.toml \
  eliza/packages/sweagent/rust/Cargo.toml
```

#### Python (all packages)

```bash
cd eliza
python scripts/update-python-versions.py 2.1.0
```

---

## GitHub Secrets Reference

These secrets must be configured in the repository settings (**Settings → Secrets and variables → Actions**):

| Secret | Required For | How to Get |
|--------|-------------|------------|
| `CRATES_IO_TOKEN` | Rust publishing | [crates.io/settings/tokens](https://crates.io/settings/tokens) — Create with `publish-new` + `publish-update` scopes |
| `PYPI_TOKEN` | Python publishing | [pypi.org/manage/account/token/](https://pypi.org/manage/account/token/) — Create with "Entire account" scope |
| `NPM_TOKEN` | TypeScript publishing | [npmjs.com/settings/~/tokens](https://www.npmjs.com/settings/~/tokens) — Create an "Automation" token |
| `GITHUB_TOKEN` | Release artifacts | Provided automatically by GitHub Actions |

### Token Rotation

Tokens should be rotated periodically:

1. Generate a new token on the respective platform
2. Update the GitHub secret in repository settings
3. Verify with a dry-run workflow dispatch
4. Revoke the old token

### Security Best Practices

- Never commit tokens to the repository
- Use the narrowest scope possible for tokens
- Enable 2FA on all registry accounts (required for PyPI)
- Prefer GitHub team ownership over individual ownership for crates.io
- Use the `--dry-run` flag before every real publish to catch issues early
