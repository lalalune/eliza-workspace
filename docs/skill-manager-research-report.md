# Skill Creator, Editor & Manager Tooling -- Research Report

**Issue:** milady-ai/milaidy#33
**Date:** February 8, 2026
**Scope:** Agent CRUD, User CRUD, Enable/Disable, Security, ClawHub Integration, Milaidy App Integration

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Current State of the Codebase](#2-current-state-of-the-codebase)
3. [Existing CRUD Capabilities (What We Already Have)](#3-existing-crud-capabilities)
4. [Skill Enable/Disable System (What We Already Have)](#4-skill-enabledisable-system)
5. [ClawHub Integration (What We Already Have + Gaps)](#5-clawhub-integration)
6. [SkillsMP Marketplace Integration (What We Already Have)](#6-skillsmp-marketplace-integration)
7. [AgentSkills.io / SKILL.md Open Format](#7-agentskillsio--skillmd-open-format)
8. [Security Analysis -- Current State](#8-security-analysis----current-state)
9. [Security Crisis -- ClawHub Malware Incidents (Feb 2026)](#9-security-crisis----clawhub-malware-incidents)
10. [Proposed Architecture: Skill Quarantine & Review Pipeline](#10-proposed-architecture-skill-quarantine--review-pipeline)
11. [Proposed Architecture: Unified Skill Manager](#11-proposed-architecture-unified-skill-manager)
12. [Implementation Recommendations](#12-implementation-recommendations)
13. [Risk Assessment](#13-risk-assessment)

---

## 1. Executive Summary

The Milaidy codebase already has **significant** skill management infrastructure in place, far more than initially expected. The core gap is not in CRUD operations (which are ~80% complete) but in:

1. **A quarantine/review pipeline** for externally sourced skills (critical given ClawHub's Feb 2026 malware crisis)
2. **A unified UI** that brings together the fragmented skill sources (bundled, workspace, ClawHub catalog, SkillsMP marketplace) into one cohesive experience
3. **Agent-side skill self-management** -- letting the agent enable/disable/search/install skills autonomously
4. **Skill editing/creation** from within the app (template-based creation + open-in-editor workflow)

The security situation is urgent. As of February 4-7, 2026, **400+ malicious skills** were found on ClawHub, **7.1% of ClawHub's 3,984 skills** contain credential-leaking vulnerabilities, and independent research shows **26.1% of skills across major marketplaces** contain at least one vulnerability. Any skill loaded from an external source MUST go through a quarantine pipeline.

---

## 2. Current State of the Codebase

### 2.1 Project Layout

The skill infrastructure spans three major codebases:

| Location | Purpose |
|---|---|
| `plugins/plugin-agent-skills/typescript/` | Core AgentSkillsService -- loading, storage, parsing, catalog sync, install |
| `openclaw/` | CLI + gateway skill management, security scanner, bundled skills |
| `milaidy/` | App UI, REST API, marketplace integration, config/preferences |

### 2.2 Key Files

**Plugin (Core Engine):**
- `plugins/plugin-agent-skills/typescript/src/services/skills.ts` (2,361 lines) -- AgentSkillsService
- `plugins/plugin-agent-skills/typescript/src/storage.ts` -- Memory + filesystem storage abstraction
- `plugins/plugin-agent-skills/typescript/src/parser.ts` -- SKILL.md parsing and validation
- `plugins/plugin-agent-skills/typescript/src/types.ts` -- All TypeScript interfaces
- `plugins/plugin-agent-skills/typescript/src/actions/` -- search-skills, get-skill-details, sync-catalog, run-skill-script

**OpenClaw (CLI + Security):**
- `openclaw/src/agents/skills.ts` -- Core skills module
- `openclaw/src/agents/skills-install.ts` -- Installation logic (brew, npm, go, uv, download)
- `openclaw/src/agents/skills-status.ts` -- Eligibility/status checking
- `openclaw/src/security/skill-scanner.ts` -- Static analysis security scanner
- `openclaw/src/cli/skills-cli.ts` -- CLI commands

**Milaidy (App):**
- `milaidy/src/api/server.ts` (4,454 lines) -- REST API with skill endpoints
- `milaidy/src/services/skill-marketplace.ts` -- SkillsMP integration
- `milaidy/src/services/skill-catalog-client.ts` -- Local catalog client
- `milaidy/apps/ui/src/ui/app.ts` (6,841 lines) -- Full UI including skills tab + marketplace

### 2.3 Skill Sources (Loading Precedence)

Skills are discovered from multiple sources with the following priority:

1. **Workspace skills** -- `~/.milaidy/workspace/skills/<skill>/SKILL.md` (highest)
2. **Managed skills** -- `~/.openclaw/skills/` or configured `skillsDir`
3. **Bundled skills** -- Read-only bundled with the app (89+ skills in OpenClaw)
4. **Plugin skills** -- Plugin-contributed skill directories
5. **Marketplace skills** -- `skills/.marketplace/<skill>/SKILL.md`
6. **Extra skill dirs** -- From config (lowest)

### 2.4 Skill Format (SKILL.md)

Every skill is a folder containing a `SKILL.md` file:

```
skill-name/
  SKILL.md              # Required: YAML frontmatter + markdown instructions
  scripts/              # Optional: executable code
  references/           # Optional: context documents
  assets/               # Optional: output templates
```

Frontmatter:
```yaml
---
name: weather                          # Required: 1-64 chars, lowercase + hyphens
description: Get weather forecasts.    # Required: 1-1024 chars
license: MIT                           # Optional
compatibility: requires curl           # Optional
metadata:                              # Optional
  openclaw:
    emoji: "..."
    requires:
      bins: ["curl"]
allowed-tools: Bash Read Write         # Optional: pre-approved tools
---
```

This format conforms to the **AgentSkills.io open standard** (originally developed by Anthropic, 9,165 GitHub stars). It is interoperable with Claude Code, OpenAI Codex CLI, ChatGPT, Cursor, and other compatible platforms.

---

## 3. Existing CRUD Capabilities

### 3.1 What We Already Have

| Operation | User (via App) | Agent (via Plugin) | Status |
|---|---|---|---|
| **Create** (from template) | Partial (manual folder creation) | Partial (skill-creator skill exists) | Needs template UI |
| **Read** (list all) | `GET /api/skills` + UI tab | `skillsSummaryProvider` in system prompt | Done |
| **Read** (search) | `GET /api/skills/catalog/search` + marketplace search UI | `search-skills` action | Done |
| **Read** (details) | `GET /api/skills/catalog/:slug` | `get-skill-details` action | Done |
| **Update** (enable/disable) | `PUT /api/skills/:id` + toggle UI | Config-based only | Needs agent action |
| **Update** (edit content) | Not implemented | Not implemented | Needs "open folder" |
| **Delete** (uninstall) | `POST /api/skills/catalog/uninstall` + marketplace uninstall | Not implemented | Needs agent action |
| **Install** (from registry) | `POST /api/skills/catalog/install` | Catalog sync + install | Done |
| **Install** (from marketplace) | `POST /api/skills/marketplace/install` + GitHub URL | Not implemented | Needs agent action |
| **Install** (from ClawHub) | Via catalog (default registry: clawhub.ai) | Via `sync-catalog` action | Done but no quarantine |

### 3.2 API Endpoints (Already Implemented in `milaidy/src/api/server.ts`)

**Read operations:**
- `GET /api/skills` -- List all discovered skills with enabled/disabled status
- `GET /api/skills/refresh` -- Force re-scan
- `GET /api/skills/catalog` -- Browse catalog (from ClawHub registry)
- `GET /api/skills/catalog/search` -- Search catalog
- `GET /api/skills/catalog/:slug` -- Get skill details
- `GET /api/skills/marketplace/search` -- Search SkillsMP
- `GET /api/skills/marketplace/installed` -- List installed marketplace skills
- `GET /api/skills/marketplace/config` -- Get marketplace API key config

**Write operations:**
- `PUT /api/skills/:id` -- Update skill (currently just enable/disable toggle)
- `POST /api/skills/catalog/install` -- Install from ClawHub catalog
- `POST /api/skills/catalog/uninstall` -- Uninstall catalog skill
- `POST /api/skills/marketplace/install` -- Install from SkillsMP/GitHub
- `POST /api/skills/marketplace/uninstall` -- Uninstall marketplace skill
- `PUT /api/skills/marketplace/config` -- Update SkillsMP API key

### 3.3 Gaps to Fill

1. **Create skill from template** -- Need a `POST /api/skills/create` endpoint that scaffolds a new skill folder from a template in `~/.milaidy/workspace/skills/`
2. **Edit skill** -- Need a `POST /api/skills/:id/open` endpoint that reveals the skill folder in Finder/Explorer or opens it in the default editor
3. **Agent-side toggle** -- Need a new action `toggle-skill` that lets the agent enable/disable skills
4. **Agent-side install** -- Need a new action `install-skill` that wraps the marketplace/catalog install
5. **Agent-side uninstall** -- Need a new action `uninstall-skill`

---

## 4. Skill Enable/Disable System

### 4.1 Current Implementation

The enable/disable system is **already well-implemented** with a clear priority chain:

```
Priority (highest first):
  1. Database preferences (per-agent, persisted via PUT /api/skills/:id)
  2. skills.denyBundled config -- always blocks
  3. skills.entries[id].enabled config -- per-skill default
  4. skills.allowBundled config -- whitelist mode
  5. Default: enabled
```

**Backend:** `milaidy/src/api/server.ts` lines 714-748 (`resolveSkillEnabled()`)

**Frontend:** Toggle switches in the Skills tab (`apps/ui/src/ui/app.ts` lines 5451-5631)

**Config:** `~/.milaidy/milaidy.json` has `skills` section:
```json
{
  "skills": {
    "allowBundled": ["weather", "github"],
    "denyBundled": ["risky-skill"],
    "entries": {
      "weather": { "enabled": true },
      "some-skill": { "enabled": false }
    }
  }
}
```

**Database:** Preferences are stored in the agent's cache table, scoped per-agent. This means each agent can have different skills enabled.

### 4.2 What Needs to Change

The current system does NOT have **enabled/disabled folders** as the user described. Instead, it uses config-based toggling. Two approaches:

**Option A: Keep config-based (recommended)**
- Already works, already persisted, already per-agent
- Just ensure the UI clearly shows enabled vs disabled
- Add agent-side actions to toggle

**Option B: Move to folder-based**
- `skills/enabled/` and `skills/disabled/` directories
- Moving a skill folder physically enables/disables it
- Simpler mental model, but loses per-agent granularity
- Harder to manage with multiple sources (bundled skills can't be moved)

**Recommendation:** Keep the config-based system (Option A) but add UI affordances that *feel* like folder management. The UI can show "Enabled" and "Disabled" sections. The agent can toggle via actions. Optionally add an "Open Skills Folder" button that opens `~/.milaidy/workspace/skills/` in the file manager.

---

## 5. ClawHub Integration

### 5.1 What ClawHub Is

ClawHub (https://clawhub.ai) is the public skill registry for OpenClaw. Key facts:

- **Scale:** 3,984 skills as of Feb 2026
- **Tech stack:** TanStack Start (React/Vite), Convex backend, GitHub OAuth, OpenAI embeddings for search
- **Features:** Browse, search (vector embeddings), star, comment, publish with changelogs/tags
- **CLI:** `npm i -g clawhub` -- `clawhub search`, `clawhub install`, `clawhub update`, `clawhub publish`, `clawhub sync`
- **No formal rating/trust system** -- Only basic starring + commenting, with admin/moderator curation
- **No verification pipeline** -- Skills are user-submitted with minimal vetting

### 5.2 What We Already Have

**Default registry:**
```typescript
// milaidy/plugins.json
"SKILLS_REGISTRY": {
  "type": "string",
  "description": "Skill registry URL (default: https://clawhub.ai)",
  "required": false,
  "example": "https://clawhub.ai"
}
```

**API endpoints already used:**
- `/api/v1/catalog` -- List all skills
- `/api/v1/search` -- Search skills
- `/api/v1/skills/:slug` -- Get skill details
- `/api/v1/download?slug=:slug&version=:version` -- Download skill package

**Catalog sync:** Background task syncs hourly, caches to `skills/.cache/catalog.json`, 10-min memory cache

**CLI hint in OpenClaw:**
```typescript
// openclaw/src/cli/skills-cli.ts
function appendClawHubHint(output: string): string {
  return `${output}\n\nTip: use \`npx clawhub\` to search, install, and sync skills.`;
}
```

**System prompt includes:**
```typescript
// openclaw/src/agents/system-prompt.ts
"Find new skills: https://clawhub.com"
```

### 5.3 ClawHub's Companion Registry

ClawHub also has a companion called **onlycrabs.ai** for publishing "system lore" through `SOUL.md` files -- personality/character definitions. This is separate from skills but worth noting for future soul/persona management.

### 5.4 Critical Gap: No Security on ClawHub Downloads

Currently, when a skill is installed from ClawHub via `POST /api/skills/catalog/install`, it downloads a ZIP, extracts it, validates the SKILL.md frontmatter, and makes it available immediately. **There is no quarantine step, no security scan, no user review.** This is the biggest gap.

---

## 6. SkillsMP Marketplace Integration

### 6.1 What SkillsMP Is

SkillsMP (https://skillsmp.com) is an open-source marketplace aggregating AI agent skills:
- **Scale:** 66,541+ skills (sourced from GitHub repositories)
- **Search:** AI-powered semantic + keyword search
- **Quality filter:** Minimum 2-star validation from GitHub
- **Categories:** Tools, Development, Data & AI, Business, DevOps, Testing, Documentation
- **Standard:** All skills conform to the SKILL.md open standard
- **Requires API key:** `SKILLSMP_API_KEY`

### 6.2 What We Already Have

Full integration in `milaidy/src/services/skill-marketplace.ts`:
- `searchSkillsMarketplace()` -- Search via API
- `installMarketplaceSkill()` -- Clone from GitHub (sparse checkout)
- `listInstalledMarketplaceSkills()` -- Track installed skills
- `uninstallMarketplaceSkill()` -- Remove with path safety checks
- Install records persisted at `skills/.cache/marketplace-installs.json`

**GitHub URL support:** Users can paste a full GitHub tree URL and the system will parse the repo, ref, and path automatically.

### 6.3 Gap

Like ClawHub, there is no quarantine step between download and availability. The `installMarketplaceSkill` function validates that `SKILL.md` exists but does not scan for malicious content.

---

## 7. AgentSkills.io / SKILL.md Open Format

### 7.1 Overview

**AgentSkills.io** (https://agentskills.io) is the official website for the SKILL.md open format:
- Originally developed by Anthropic, released as open standard
- Spec maintained at https://github.com/anthropics/skills
- 9,165 GitHub stars
- Adopted by Claude Code, OpenAI Codex CLI, ChatGPT, Cursor, and others

### 7.2 Security Fields in the Spec

The specification includes permission/security fields that we should leverage:
- **allowed-tools** -- Space-delimited pre-approved tool list
- **Filesystem access** -- read/write/deny paths
- **Network access** -- allowed/denied hosts
- **Bash command allowlists/denylists**

### 7.3 Our Compliance

Our SKILL.md parser and validator already handle the core spec. The `allowed-tools` field is parsed. Filesystem/network access fields are not currently enforced at runtime.

---

## 8. Security Analysis -- Current State

### 8.1 What We Already Have

**1. Static Analysis Scanner** (`openclaw/src/security/skill-scanner.ts`)

A file-based scanner that checks `.js`, `.ts`, `.mjs`, `.cjs`, `.jsx`, `.tsx` files for dangerous patterns:

| Rule | Severity | What it detects |
|---|---|---|
| `dangerous-exec` | Critical | `child_process.exec/spawn` calls |
| `dynamic-code-execution` | Critical | `eval()`, `new Function()` |
| `crypto-mining` | Critical | stratum, coinhive, xmrig references |
| `env-harvesting` | Critical | `process.env` + network send |
| `potential-exfiltration` | Warn | File read + network send |
| `obfuscated-code` | Warn | Hex-encoded strings, large base64 |
| `suspicious-network` | Warn | WebSocket to non-standard ports |

Limitations:
- Only scans `.js`/`.ts` files, NOT `.md` files (where malicious instructions live!)
- Does not scan `SKILL.md` content for prompt injection or social engineering
- Does not check for external URL references in markdown
- 10MB max file, 500 file limit
- No integration with the install pipeline (scanner exists but is not called on install)

**2. Input Validation**
- Package name regex: `^(@[a-zA-Z0-9][\w.-]*\/)?[a-zA-Z0-9][\w.-]*$`
- Version regex, git URL regex, branch regex (shell injection prevention)
- GitHub-only URL restriction for marketplace installs

**3. Package Size Limits**
- 10MB max for downloaded ZIP packages
- Enforced in both TypeScript and Rust implementations

**4. Allowlist/Denylist**
- `isSkillAllowed()` checks against configured allow/deny lists
- `denyBundled` always blocks
- `allowBundled` operates as whitelist mode

**5. Protected Plugins**
- Plugin manager has a hardcoded set of protected plugins that cannot be unloaded

**6. Sandbox Service**
- `plugin-agent-orchestrator` has a `SandboxService` for tool execution isolation
- Docker-based container isolation
- Tool allow/deny policies

**7. Trust System**
- `plugin-trust` has a `ContextualPermissionSystem` with:
  - Prompt injection detection
  - Role-based access control
  - Trust score thresholds
  - Delegation and elevation mechanisms

### 8.2 What We're Missing

1. **Quarantine folder** -- Downloaded skills go live immediately
2. **SKILL.md content scanning** -- Markdown instructions are not scanned for malicious URLs, social engineering, or prompt injection
3. **Scanner not wired into install pipeline** -- The skill-scanner.ts exists but isn't called during `installFromUrl()` or `installMarketplaceSkill()`
4. **No user review step** -- No "review before activate" workflow
5. **No provenance tracking** -- No record of where a skill came from, who published it, or its verification status
6. **No integrity checking** -- No hash verification of downloaded packages
7. **Runtime sandboxing for skills** -- Skills can instruct the agent to do anything; no per-skill permission enforcement
8. **No scanning of Python/shell scripts** -- Only JS/TS files are scanned

---

## 9. Security Crisis -- ClawHub Malware Incidents

### 9.1 Timeline (January-February 2026)

| Date | Event |
|---|---|
| Jan 27-29 | 28 malicious skills uploaded to ClawHub (crypto stealers) |
| Jan 31 - Feb 2 | 386 more malicious skills uploaded |
| Feb 3 | OpenSourceMalware publishes report |
| Feb 4 | 1Password's Jason Meller publishes analysis |
| Feb 4 | The Verge reports "security nightmare" |
| Feb 5 | Snyk discovers 283 skills (7.1%) leaking credentials in plaintext |
| Feb 7 | OpenClaw partners with VirusTotal for scanning |
| Feb 7 | ClawHub requires GitHub accounts > 1 week old to publish |

### 9.2 Attack Vectors Found

1. **Malicious SKILL.md instructions** -- Markdown files containing URLs that trick the agent into downloading malware
2. **Credential harvesting** -- Skills instructing agents to pass API keys through LLM context windows in plaintext
3. **Crypto theft** -- Skills masquerading as trading tools, stealing exchange API keys, wallet keys, SSH credentials, browser passwords
4. **Social engineering via markdown** -- The most-downloaded ClawHub add-on (a "Twitter" skill) contained hidden instructions to navigate to a malware download URL

### 9.3 Industry Research

- **26.1%** of skills across major marketplaces contain at least one vulnerability
- **13.3%** risk data exfiltration
- **11.8%** enable privilege escalation
- **5.2%** show patterns suggesting malicious intent
- Skills with bundled scripts are **2.12x** more likely to contain vulnerabilities than instruction-only skills

### 9.4 OpenClaw's Response

- Partnered with VirusTotal for scanning (acknowledged as "not a silver bullet")
- Required GitHub accounts > 1 week old to publish
- Added skill reporting mechanism
- No formal quarantine or multi-stage review process

---

## 10. Proposed Architecture: Skill Quarantine & Review Pipeline

### 10.1 Three-Stage Pipeline

```
DOWNLOAD --> QUARANTINE --> REVIEW --> ACTIVE
                |              |
                v              v
            [Scanned]    [User/Agent
             Auto-scan    Approved]
```

**Stage 1: Download to Quarantine**

When a skill is downloaded from any external source (ClawHub, SkillsMP, GitHub URL):

```
~/.milaidy/workspace/skills/
  .quarantine/             <-- NEW: quarantined skills land here
    <skill-id>/
      SKILL.md
      scripts/
      .quarantine-meta.json  <-- provenance, scan results, timestamps
  .marketplace/            <-- existing: approved marketplace skills
  <active-skills>/         <-- existing: user-created and approved skills
```

**Stage 2: Automatic Security Scan**

Run immediately after download, before any user interaction:

1. **Existing scanner** -- Run `skill-scanner.ts` on all JS/TS files
2. **NEW: Markdown scanner** -- Scan SKILL.md for:
   - External URLs (flag any non-allowlisted domains)
   - Shell command instructions (curl, wget, bash, etc.)
   - File system manipulation instructions
   - Credential/env var references
   - Base64 encoded content
   - Obfuscated text patterns
3. **NEW: Manifest validator** -- Ensure:
   - No binaries present (`.exe`, `.dll`, `.so`, `.dylib`, `.wasm`)
   - No compiled artifacts
   - No symlinks pointing outside skill directory
   - File count and total size within limits
   - No hidden files (dotfiles) except `.quarantine-meta.json`
4. **NEW: VirusTotal integration** -- If configured, submit suspicious files
5. **Score the skill:** `CLEAN`, `WARNING`, `CRITICAL`, `BLOCKED`

**Stage 3: User Review**

- `BLOCKED` skills are auto-rejected with explanation
- `CRITICAL` skills require explicit user acknowledgment of each finding
- `WARNING` skills show findings but allow one-click approval
- `CLEAN` skills can be auto-approved (configurable) or shown with green checkmark

**Quarantine metadata file:**
```json
{
  "skillId": "weather-pro",
  "source": "clawhub",
  "sourceUrl": "https://clawhub.ai/skills/weather-pro",
  "downloadedAt": "2026-02-08T10:00:00Z",
  "publisher": "github:someuser",
  "version": "1.2.0",
  "scanResults": {
    "scannedAt": "2026-02-08T10:00:01Z",
    "status": "WARNING",
    "findings": [...],
    "fileCount": 5,
    "totalBytes": 12400,
    "hasBinaries": false,
    "hasExternalUrls": true,
    "externalUrls": ["https://api.weather.com"]
  },
  "reviewStatus": "pending",
  "reviewedAt": null,
  "reviewedBy": null
}
```

### 10.2 Enhanced Scanner Rules (New)

Add to the existing `skill-scanner.ts`:

```typescript
// New markdown-specific rules
const MARKDOWN_RULES = [
  { id: "md-external-url", severity: "warn",
    pattern: /https?:\/\/(?!github\.com|clawhub\.(ai|com)|skillsmp\.com)[^\s)]+/g,
    message: "External URL detected in skill instructions" },
  { id: "md-shell-command", severity: "warn",
    pattern: /```(?:bash|sh|shell|zsh)\n[\s\S]*?```/g,
    message: "Shell commands in skill instructions" },
  { id: "md-curl-wget", severity: "critical",
    pattern: /\b(curl|wget|fetch)\s+https?:\/\//gi,
    message: "Download command targeting external URL" },
  { id: "md-env-reference", severity: "warn",
    pattern: /\$\{?\w*(?:KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)\w*\}?/gi,
    message: "Credential/secret reference in instructions" },
  { id: "md-prompt-injection", severity: "critical",
    pattern: /ignore\s+(previous|above|all)\s+instructions/gi,
    message: "Possible prompt injection attempt" },
];

// New file manifest rules
const MANIFEST_RULES = [
  { id: "binary-file", severity: "critical",
    extensions: [".exe", ".dll", ".so", ".dylib", ".wasm", ".bin", ".com"],
    message: "Binary file detected" },
  { id: "hidden-file", severity: "warn",
    pattern: /^\./,
    message: "Hidden file detected" },
  { id: "symlink", severity: "critical",
    check: "isSymlink",
    message: "Symbolic link detected" },
];
```

### 10.3 API Endpoints (New)

```
GET  /api/skills/quarantine          -- List quarantined skills
GET  /api/skills/quarantine/:id      -- Get quarantine details + scan results
POST /api/skills/quarantine/:id/approve  -- Move to active skills
POST /api/skills/quarantine/:id/reject   -- Delete quarantined skill
POST /api/skills/quarantine/:id/rescan   -- Re-run security scan
```

### 10.4 ClawHub-Specific Trust Signals

Since ClawHub lacks a formal trust system, we should build our own trust scoring:

```
Trust Score = weighted sum of:
  - Publisher account age (GitHub account > 1 week = +1, > 6 months = +3, > 1 year = +5)
  - ClawHub stars (log scale: 1-5 = +1, 5-20 = +2, 20+ = +3)
  - Number of skills by publisher (> 5 = +1, > 20 = +2)
  - Security scan result (CLEAN = +5, WARNING = +2, CRITICAL = -10)
  - Known publisher (in our local allowlist = +10)
  - Skill age on ClawHub (> 30 days = +2, > 90 days = +3)
  - Has source repository (verifiable GitHub link = +2)
```

Skills with trust score >= threshold can be auto-approved from quarantine (configurable).

---

## 11. Proposed Architecture: Unified Skill Manager

### 11.1 UI Architecture (Milaidy App)

Enhance the existing Skills tab into a full skill management experience:

```
Skills Tab
  |
  +-- My Skills (workspace skills)
  |     +-- [+ Create New Skill]  <-- from template
  |     +-- Skill Card (name, desc, toggle, [Edit] [Delete])
  |     +-- ...
  |
  +-- Installed Skills (catalog + marketplace)
  |     +-- Skill Card (name, desc, source badge, toggle, [Uninstall])
  |     +-- ...
  |
  +-- Quarantine (pending review)
  |     +-- Skill Card (name, desc, source, scan status, [Review] [Reject])
  |     +-- ...
  |
  +-- Browse & Search
        +-- Search bar (searches ClawHub + SkillsMP simultaneously)
        +-- Source filter: [All] [ClawHub] [SkillsMP]
        +-- Result Cards (name, desc, source, stars/score, [Install])
```

### 11.2 Skill Creation Flow

```
User clicks [+ Create New Skill]
  --> Modal: skill name + description
  --> System scaffolds:
      ~/.milaidy/workspace/skills/<skill-name>/
        SKILL.md   (pre-filled template)
  --> Opens folder in default editor / reveals in Finder
  --> Skill auto-discovered on next refresh (filesystem watcher)
```

**Template for new skill:**
```yaml
---
name: my-new-skill
description: Describe what this skill does and when to use it.
---

## Instructions

[Write your skill instructions here]

## When to Use

Use this skill when [describe trigger conditions].

## Steps

1. [Step 1]
2. [Step 2]
3. [Step 3]
```

### 11.3 Skill Editing Flow

```
User clicks [Edit] on a skill
  --> If workspace skill: open folder in editor
  --> If bundled/installed skill:
      --> Copy to workspace (to preserve original)
      --> Open copy in editor
      --> Workspace copy takes precedence (by loading order)
```

### 11.4 Agent-Side Skill Management

New actions for the agent (add to `plugin-agent-skills`):

| Action | Description |
|---|---|
| `list-skills` | List all skills with enabled/disabled status |
| `toggle-skill` | Enable or disable a skill by ID |
| `search-skills` | Search across ClawHub + SkillsMP (already exists, enhance) |
| `install-skill` | Install from any source (goes to quarantine first) |
| `uninstall-skill` | Uninstall a non-bundled skill |
| `review-quarantine` | List quarantined skills and their scan results |
| `approve-skill` | Approve a quarantined skill (move to active) |

**Agent visibility:**
- Agent can see ALL skills (enabled, disabled, quarantined) via providers
- Agent can search ClawHub and SkillsMP
- Agent CANNOT bypass quarantine (install always goes through pipeline)
- Agent CAN auto-approve skills with trust score >= threshold (configurable)

### 11.5 Progressive Disclosure

The existing progressive disclosure system is well-designed and should be preserved:

- **Level 1 (Metadata):** ~100 tokens per skill in system prompt -- name + description
- **Level 2 (Instructions):** <5k tokens loaded when skill triggers
- **Level 3 (Resources):** Unlimited, loaded on-demand (scripts, references, assets)

---

## 12. Implementation Recommendations

### 12.1 Priority Order

| Priority | Item | Effort | Impact |
|---|---|---|---|
| **P0** | Wire scanner into install pipeline | Small | Critical security fix |
| **P0** | Add SKILL.md content scanning | Medium | Critical security fix |
| **P0** | Implement quarantine folder + review flow | Medium | Critical security fix |
| **P1** | Add quarantine API endpoints | Small | Enables UI + agent |
| **P1** | Add quarantine UI section | Medium | User-facing review |
| **P1** | Add agent toggle-skill action | Small | Agent self-management |
| **P1** | Add skill creation from template | Small | User skill creation |
| **P1** | Add "open in editor" for skill editing | Small | User skill editing |
| **P2** | Add binary/manifest validation | Small | Defense in depth |
| **P2** | Add trust scoring for ClawHub | Medium | Auto-approval workflow |
| **P2** | Add agent install/uninstall actions | Medium | Full agent CRUD |
| **P2** | Unified search across all sources | Medium | Better UX |
| **P3** | VirusTotal integration | Medium | External validation |
| **P3** | Runtime per-skill sandboxing | Large | Defense in depth |
| **P3** | Provenance/integrity tracking | Medium | Supply chain security |

### 12.2 Files to Modify

**New files:**
- `milaidy/src/services/skill-quarantine.ts` -- Quarantine service
- `milaidy/src/services/skill-scanner-enhanced.ts` -- Enhanced scanner (markdown + manifest)
- `plugins/plugin-agent-skills/typescript/src/actions/toggle-skill.ts` -- Agent toggle action
- `plugins/plugin-agent-skills/typescript/src/actions/install-skill.ts` -- Agent install action
- `plugins/plugin-agent-skills/typescript/src/actions/uninstall-skill.ts` -- Agent uninstall action

**Modify:**
- `milaidy/src/api/server.ts` -- Add quarantine endpoints, wire scanner into install flow
- `milaidy/src/services/skill-marketplace.ts` -- Route installs through quarantine
- `milaidy/apps/ui/src/ui/app.ts` -- Enhanced skills tab UI
- `plugins/plugin-agent-skills/typescript/src/services/skills.ts` -- Wire scanner into `installFromUrl()`
- `plugins/plugin-agent-skills/typescript/src/plugin.ts` -- Register new actions
- `openclaw/src/security/skill-scanner.ts` -- Add markdown scanning rules

### 12.3 Backward Compatibility

- Existing bundled and workspace skills continue to work unchanged (they're trusted)
- Only externally downloaded skills go through quarantine
- The quarantine can be configured to auto-approve (for advanced users who want the old behavior)
- CLI (`npx clawhub install`) should also route through the quarantine when Milaidy is running

---

## 13. Risk Assessment

### 13.1 Security Risks (Current)

| Risk | Severity | Current Mitigation | Recommended |
|---|---|---|---|
| Malicious ClawHub skills | **Critical** | None (direct install) | Quarantine + scan |
| Credential leaking in instructions | **High** | None | SKILL.md content scan |
| Prompt injection via SKILL.md | **High** | None | Pattern detection |
| Binary payload in skill package | **High** | 10MB size limit only | Manifest validation |
| Supply chain attack via GitHub | **Medium** | GitHub-only URL restriction | Hash verification |
| Runtime privilege escalation | **Medium** | Trust system exists | Per-skill sandboxing |

### 13.2 Implementation Risks

| Risk | Mitigation |
|---|---|
| Quarantine friction annoys users | Auto-approve for CLEAN scans (configurable) |
| Scanner false positives | Start with conservative rules, add allowlists |
| Performance impact of scanning | Scan only on install (one-time), cache results |
| Agent bypassing quarantine | Enforce at API level, not just UI level |

---

## Appendix A: External Service Reference

| Service | URL | Purpose | Auth |
|---|---|---|---|
| ClawHub | https://clawhub.ai | Skill registry (default) | GitHub OAuth |
| SkillsMP | https://skillsmp.com | Skill marketplace | API key (SKILLSMP_API_KEY) |
| AgentSkills.io | https://agentskills.io | SKILL.md spec & docs | None |
| VirusTotal | https://virustotal.com | Malware scanning | API key |

## Appendix B: Relevant GitHub Repositories

| Repo | Stars | Purpose |
|---|---|---|
| openclaw/clawhub | 725 | ClawHub registry source |
| agentskills/agentskills | 9,165 | SKILL.md open format spec |
| anthropics/skills | -- | Original spec + reference skills |
| milady-ai/milaidy | -- | Milaidy app source |

## Appendix C: Key Code References

```
# Core skill service (2,361 lines)
plugins/plugin-agent-skills/typescript/src/services/skills.ts

# Security scanner (442 lines)
openclaw/src/security/skill-scanner.ts

# Marketplace service (436 lines)
milaidy/src/services/skill-marketplace.ts

# REST API server -- skill endpoints (lines 3445-3900)
milaidy/src/api/server.ts

# Skills UI (lines 5451-5631)
milaidy/apps/ui/src/ui/app.ts

# Enable/disable resolution (lines 714-748)
milaidy/src/api/server.ts

# Skill types and interfaces
plugins/plugin-agent-skills/typescript/src/types.ts

# Skill parser and validator
plugins/plugin-agent-skills/typescript/src/parser.ts

# 89+ bundled skills
openclaw/skills/

# Skill creator template
openclaw/skills/skill-creator/SKILL.md
```
