# milady-workspace

A **git-submodule monorepo** for developing [milaidy](https://github.com/milady-ai/milaidy) alongside [ElizaOS](https://github.com/elizaos/eliza) and its plugin ecosystem. One workspace, one clone, every repo you need wired together.

## Why a workspace?

Milaidy depends on ElizaOS core, dozens of plugins, and several companion projects. Normally you'd juggle separate clones, manually link packages, and hope the versions line up. The workspace solves this by pinning every dependency as a **git submodule** at a known-good commit, so the entire stack is checked out, built, and developed in one tree.

```
milady-workspace/
├── eliza/          # ElizaOS core runtime & packages (submodule → elizaos/eliza)
├── milaidy/        # Milaidy agent & app              (submodule → milady-ai/milaidy)
├── plugins/        # All @elizaos plugins              (submodule → lalalune/plugins)
├── registry/       # Plugin registry                   (submodule → elizaOS-plugins/registry)
├── examples/       # ElizaOS example projects          (submodule → elizaOS/examples)
├── dungeons/       # Dungeons game agent               (submodule → lalalune/dungeons)
├── benchmarks/     # Performance benchmarks            (submodule → elizaOS/benchmarks)
├── scripts/        # Setup, dev, and publish scripts
├── package.json    # Workspace-level npm scripts
└── PUBLISHING.md   # Full guide for npm / crates.io / PyPI publishing
```

Each subfolder is its own git repository. You commit, branch, and push inside each submodule independently. The root repo just tracks *which commit* of each submodule the workspace uses.

## Quick start

### Prerequisites

- **Node.js** 20+
- **Bun** (used by ElizaOS core): `curl -fsSL https://bun.sh/install | bash`
- **npm** (used by milaidy, dungeons, registry)
- **git** with submodule support

### Clone and setup

```bash
# Clone with submodules in one shot
git clone --recurse-submodules https://github.com/milady-ai/milady-workspace.git
cd milady-workspace

# Full setup: init submodules → install deps → build everything
npm run setup
```

The `setup` script:
1. Initializes all git submodules recursively
2. Installs dependencies in each project (bun for eliza, npm for milaidy/dungeons/registry)
3. Builds all packages

#### Setup variants

```bash
npm run setup              # full setup (submodules + deps + build)
npm run setup:quick        # skip the build step (submodules + deps only)
npm run setup:update       # pull latest commits from all submodule remotes
```

### Start developing

```bash
npm run dev                # start all dev servers (eliza + dungeons + milaidy)
npm run dev:eliza          # start only eliza
npm run dev:milaidy        # start only milaidy
npm run dev:dungeons       # start only dungeons
```

Dev servers run as background processes managed by a single script. Press `Ctrl+C` to stop them all.

## How submodules work

### Checking submodule status

```bash
git submodule status
```

This shows the pinned commit for each submodule and whether it's been modified locally.

### Updating submodules

```bash
# Pull whatever commit the workspace repo pins (safe, deterministic)
npm run submodules:init

# Pull the latest from each submodule's remote branch
npm run submodules:update
```

### Working inside a submodule

Each submodule is a normal git repo. You `cd` into it, make changes, commit, push — everything works the way you'd expect:

```bash
cd milaidy
git checkout -b my-feature
# ... make changes ...
git add -A && git commit -m "feat: new thing"
git push origin my-feature
```

When you want the root workspace to track your new commit, go back to the root and commit the submodule pointer:

```bash
cd ..
git add milaidy
git commit -m "update milaidy submodule"
```

## Publishing

The workspace includes a full publishing pipeline for shipping packages to **npm**, **crates.io**, and **PyPI**. All scripts live in `scripts/` and are exposed as npm scripts.

### npm publishing

```bash
npm run publish:all           # publish plugins + packages + fix dist-tags
npm run publish:plugins       # publish only @elizaos plugins
npm run publish:packages      # publish only @elizaos core packages

# Dry runs (show what would be published without uploading)
npm run publish:all:dry
npm run publish:plugins:dry
npm run publish:packages:dry
```

Publishing follows a **tiered dependency order**:

| Step | What | Why |
|------|------|-----|
| 1 | Plugins (tier 1: no inter-plugin deps) | Safe to publish in any order |
| 2 | Plugins (tier 2: depend on other plugins) | Tier 1 must exist on npm first |
| 3 | Packages (foundation → core → dependent) | Strict dependency chain |
| 4 | Dist-tag verification | Ensures `next` tag points to correct versions |

### Plugin distribution

Individual plugins can also be pushed as standalone repos to the `elizaos-plugins` GitHub org:

```bash
npm run push:plugins          # push all plugins to elizaos-plugins org
```

This initializes each plugin directory as its own git repo and pushes to `https://github.com/elizaos-plugins/plugin-<name>`.

### Rust and Python

See [PUBLISHING.md](./PUBLISHING.md) for the full guide covering crates.io and PyPI publishing, including WASM builds, maturin packages, CI/CD workflows, and troubleshooting.

## Build utilities

The workspace ships a shared `scripts/build-utils.ts` module used by packages throughout the monorepo. It provides:

- **`createElizaBuildConfig()`** — Standardized Bun.build configuration with automatic externals for `@elizaos/*` packages and Node.js builtins
- **`runBuild()` / `createBuildRunner()`** — Build runner with watch mode (`--watch`), clean, asset copying, and TypeScript declaration generation
- **`cleanBuild()`** — Safe artifact cleanup with retry logic for busy files
- **`copyAssets()`** — Parallel asset copying with error handling
- **`generateDts()`** — TypeScript declaration generation via `tsc`

## All npm scripts

| Script | Description |
|--------|-------------|
| `npm run setup` | Full workspace setup (submodules + deps + build) |
| `npm run setup:quick` | Setup without building |
| `npm run setup:update` | Pull latest from all submodule remotes |
| `npm run dev` | Start all dev servers |
| `npm run dev:eliza` | Start only ElizaOS dev server |
| `npm run dev:milaidy` | Start only milaidy dev server |
| `npm run dev:dungeons` | Start only dungeons dev server |
| `npm run publish:all` | Publish everything to npm |
| `npm run publish:plugins` | Publish plugins to npm |
| `npm run publish:packages` | Publish core packages to npm |
| `npm run push:plugins` | Push plugins to GitHub org repos |
| `npm run dist-tags` | Verify/fix npm dist-tags |
| `npm run submodules:init` | Initialize submodules |
| `npm run submodules:update` | Update submodules to latest remote |

## Repository layout detail

### Submodules

| Directory | Repository | Description |
|-----------|-----------|-------------|
| `eliza/` | [elizaos/eliza](https://github.com/elizaos/eliza) | Core ElizaOS runtime, packages, CLI, and TUI |
| `milaidy/` | [milady-ai/milaidy](https://github.com/milady-ai/milaidy) | Milaidy agent runtime and web app |
| `plugins/` | [lalalune/plugins](https://github.com/lalalune/plugins) | All `@elizaos/plugin-*` packages (TypeScript, Rust, Python) |
| `registry/` | [elizaOS-plugins/registry](https://github.com/elizaOS-plugins/registry) | Plugin registry and discovery |
| `examples/` | [elizaOS/examples](https://github.com/elizaOS/examples) | Example ElizaOS projects and starter templates |
| `dungeons/` | [lalalune/dungeons](https://github.com/lalalune/dungeons) | Dungeons game agent built on ElizaOS |
| `benchmarks/` | [elizaOS/benchmarks](https://github.com/elizaOS/benchmarks) | Performance benchmarks for ElizaOS |

### Root files

| File | Purpose |
|------|---------|
| `package.json` | Workspace npm scripts |
| `.gitmodules` | Submodule URL and path definitions |
| `PUBLISHING.md` | Full Rust + Python + npm publishing guide |
| `scripts/build-utils.ts` | Shared Bun build configuration utilities |
| `scripts/setup.sh` | One-command workspace setup |
| `scripts/dev.sh` | Multi-project dev server launcher |
| `scripts/publish-*.sh` | Publishing scripts for npm, plugins, packages |
| `scripts/push-plugins.sh` | Push plugins to individual GitHub repos |
| `scripts/ensure-dist-tags.sh` | Verify npm dist-tags are correct |

## License

MIT
