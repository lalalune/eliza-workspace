# Skill Creator, Editor & Manager -- Critical Implementation Plan

**Issue:** milady-ai/milaidy#33
**Date:** February 8, 2026
**Status:** Ready for implementation

---

## Guiding Principles

1. **Reuse existing code** -- The codebase already has ~80% of what we need. Every new line should integrate with, not duplicate, existing patterns.
2. **Hook, don't fork** -- Insert security scanning into existing install flows rather than creating parallel flows.
3. **Smallest surface area** -- Each change should be minimal and testable in isolation.
4. **No `unknown` or `any`** -- All new code uses concrete types per project rules.

---

## Part 1: Security Scanning Pipeline

This is the highest priority. Every external skill install must go through scanning before becoming active.

### 1.1 The Core Problem

There are exactly **three install entry points** in the codebase today:

| Entry Point | File | Method | Source |
|---|---|---|---|
| Catalog install | `plugin-agent-skills/.../services/skills.ts` | `install(slug, opts)` | ClawHub registry |
| URL install | `plugin-agent-skills/.../services/skills.ts` | `installFromUrl(url, opts)` | Direct URL / GitHub |
| Marketplace install | `milaidy/src/services/skill-marketplace.ts` | `installMarketplaceSkill(workspaceDir, input)` | SkillsMP / GitHub URL |

All three end with the skill being immediately available. None call the scanner.

The existing scanner at `openclaw/src/security/skill-scanner.ts` has the right architecture: rule-based pattern matching with severity levels, directory walking, and summary generation. But it only scans JS/TS files and is never called from any install path.

### 1.2 Approach Analysis

**Approach A: Quarantine folder with move-on-approve**

Skills download to `.quarantine/`, user reviews scan results, then approves to move them to the active directory.

- Pros: Maximum safety, clear mental model, user reviews before activation
- Cons: Adds friction, requires new UI section, new API endpoints, new state management, marketplace install records need updating after move
- Complexity: High

**Approach B: Scan-on-install with blocking**

Scanner runs during install. If CRITICAL findings, install is rejected. If WARN findings, install succeeds but skill starts disabled with a warning badge. If CLEAN, install succeeds normally.

- Pros: Reuses existing install flows, minimal new code, no new folder management, works with existing enable/disable, scan results stored as metadata
- Cons: No manual review step for WARN skills (but they start disabled), user can still enable a WARN skill
- Complexity: Low-Medium

**Approach C: Scan-on-install with confirmation gate**

Like Approach B but WARN and CRITICAL skills require an explicit API call to "acknowledge" before they can be enabled. Scan results are stored alongside the skill.

- Pros: Balances safety and UX, uses existing enable/disable, adds acknowledgment layer without full quarantine folder management
- Cons: Slightly more complex than B, needs ack tracking
- Complexity: Medium

**Recommendation: Approach C (scan-on-install with confirmation gate)**

This is the cleanest integration because:
- It hooks into the existing three install paths without changing their signatures
- It uses the existing enable/disable system (skills with findings start disabled)
- It stores scan results as metadata alongside the skill (`.scan-results.json`)
- It only adds one new concept: "acknowledgment" -- a flag that WARN/CRITICAL skills need before they can be enabled
- No folder moves, no duplicate storage, no record migration

### 1.3 Detailed Design: Enhanced Scanner

**File: `plugins/plugin-agent-skills/typescript/src/security/skill-scanner.ts`** (NEW -- adapted from `openclaw/src/security/skill-scanner.ts`)

Why a new file here instead of importing from openclaw? Because:
- `plugin-agent-skills` is the package that handles install for the Milaidy app
- `openclaw` is a separate product; we shouldn't create a cross-dependency
- We can adapt and extend the patterns from the openclaw scanner

The scanner needs three capabilities the openclaw scanner lacks:

**1. Markdown content scanning** -- The Feb 2026 attacks were almost entirely in SKILL.md markdown instructions, not in JS code. The biggest "Twitter" skill attack was a URL in markdown that tricked the agent into downloading malware. We MUST scan SKILL.md.

```typescript
// New rule category: MARKDOWN_LINE_RULES
const MARKDOWN_LINE_RULES: LineRule[] = [
  {
    ruleId: "md-download-command",
    severity: "critical",
    message: "Download command targeting external URL in skill instructions",
    pattern: /\b(curl|wget)\s+(-[a-zA-Z]*\s+)*https?:\/\//i,
  },
  {
    ruleId: "md-pipe-to-shell",
    severity: "critical",
    message: "Pipe-to-shell pattern detected (common malware vector)",
    pattern: /\|\s*(ba)?sh\b|\|\s*sudo\b/,
  },
  {
    ruleId: "md-prompt-injection",
    severity: "critical",
    message: "Possible prompt injection -- instruction override attempt",
    pattern: /ignore\s+(all\s+)?(previous|prior|above|earlier)\s+(instructions|rules|guidelines)/i,
  },
  {
    ruleId: "md-credential-exfil",
    severity: "critical",
    message: "Instruction to send credentials/keys to external service",
    pattern: /send\s+(the\s+)?(api[_\s]?key|token|secret|password|credential|private[_\s]?key)\s+(to|via|using)\b/i,
  },
  {
    ruleId: "md-external-url",
    severity: "warn",
    message: "External URL in skill instructions (review manually)",
    // Flag URLs that aren't to known-safe domains
    pattern: /https?:\/\/(?!(github\.com|githubusercontent\.com|clawhub\.(ai|com)|skillsmp\.com|agentskills\.io|npmjs\.com|pypi\.org)\b)[^\s)\]]+/,
  },
  {
    ruleId: "md-env-access",
    severity: "warn",
    message: "References environment variable access in instructions",
    pattern: /\$\{?\w*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|PRIVATE)\w*\}?/i,
  },
  {
    ruleId: "md-file-write",
    severity: "warn",
    message: "Instruction to write/modify system files",
    pattern: /write\s+to\s+[/~]|modify\s+[/~]|echo\s+.*>\s*[/~]/i,
  },
];
```

**2. Manifest validation** -- Check the file tree itself, not just file contents.

```typescript
interface ManifestFinding {
  ruleId: string;
  severity: SkillScanSeverity;
  message: string;
  file: string;
}

const BINARY_EXTENSIONS = new Set([
  ".exe", ".dll", ".so", ".dylib", ".wasm", ".bin",
  ".com", ".bat", ".cmd", ".msi", ".deb", ".rpm",
]);

const SUSPICIOUS_EXTENSIONS = new Set([
  ".sh", ".bash", ".ps1", ".psm1",
]);

async function scanManifest(dirPath: string): Promise<ManifestFinding[]> {
  // Walk directory, check:
  // 1. Binary files (CRITICAL)
  // 2. Symlinks pointing outside skill dir (CRITICAL)
  // 3. Hidden files/dirs other than allowed ones (WARN)
  // 4. Shell scripts (WARN -- not blocked, but flagged)
  // 5. Total file count > 100 (WARN)
  // 6. Total size > 5MB (WARN)
  // 7. No SKILL.md present (CRITICAL -- invalid skill)
}
```

**3. Unified scan function** that runs all three scan types:

```typescript
interface SkillScanReport {
  scannedAt: string;
  status: "clean" | "warning" | "critical" | "blocked";
  summary: {
    scannedFiles: number;
    critical: number;
    warn: number;
    info: number;
  };
  findings: SkillScanFinding[];
  manifestFindings: ManifestFinding[];
  skillPath: string;
}

async function scanSkill(skillDirPath: string): Promise<SkillScanReport> {
  const codeFindings = await scanDirectory(skillDirPath);    // Existing: JS/TS files
  const mdFindings = await scanMarkdownFiles(skillDirPath);  // New: SKILL.md + .md files
  const manifestFindings = await scanManifest(skillDirPath); // New: File tree validation

  const allFindings = [...codeFindings, ...mdFindings];
  const allManifest = manifestFindings;

  const criticalCount = allFindings.filter(f => f.severity === "critical").length
    + allManifest.filter(f => f.severity === "critical").length;
  const warnCount = allFindings.filter(f => f.severity === "warn").length
    + allManifest.filter(f => f.severity === "warn").length;

  let status: SkillScanReport["status"];
  if (allManifest.some(f => f.ruleId === "binary-file" || f.ruleId === "symlink-escape")) {
    status = "blocked";  // Hard block -- these are never okay
  } else if (criticalCount > 0) {
    status = "critical";
  } else if (warnCount > 0) {
    status = "warning";
  } else {
    status = "clean";
  }

  return {
    scannedAt: new Date().toISOString(),
    status,
    summary: { scannedFiles: ..., critical: criticalCount, warn: warnCount, info: ... },
    findings: allFindings,
    manifestFindings: allManifest,
    skillPath: skillDirPath,
  };
}
```

### 1.4 Wiring the Scanner into Install Paths

**The key insight:** All three install methods end with a skill directory on disk. We scan AFTER extraction but BEFORE making it available.

**Hook point 1: `AgentSkillsService.install()` (catalog install)**

Currently at line ~2155 in `skills.ts`, after `saveFromZip()` and before `loadSkill()`:

```typescript
// EXISTING:
await storage.saveFromZip(safeSlug, new Uint8Array(zipBuffer));
await this.updateLockfile(safeSlug, resolvedVersion);
// INSERT SCAN HERE
await this.loadSkill(safeSlug);
```

We insert:

```typescript
await storage.saveFromZip(safeSlug, new Uint8Array(zipBuffer));
await this.updateLockfile(safeSlug, resolvedVersion);

// NEW: Security scan
const skillPath = storage.getSkillPath(safeSlug);
const scanReport = await scanSkill(skillPath);
await this.saveScanReport(safeSlug, scanReport);

if (scanReport.status === "blocked") {
  await storage.deleteSkill(safeSlug);
  throw new Error(`Skill "${safeSlug}" blocked: ${scanReport.manifestFindings.map(f => f.message).join(", ")}`);
}

await this.loadSkill(safeSlug);

// If findings exist, skill is loaded but starts disabled
if (scanReport.status === "critical" || scanReport.status === "warning") {
  this.skillScanFlags.set(safeSlug, scanReport.status);
}
```

**Hook point 2: `installFromUrl()` and `installFromGitHub()`**

Same pattern -- scan after save, before load. These methods use the same storage layer so the hook point is identical.

**Hook point 3: `installMarketplaceSkill()` in `milaidy/src/services/skill-marketplace.ts`**

Currently at line 378, after `runGitCloneSubset()` and SKILL.md validation:

```typescript
// EXISTING:
await runGitCloneSubset(repository, gitRef, skillPath, targetDir);
const validSkill = await fs.stat(skillDoc).then((s) => s.isFile()).catch(() => false);
// INSERT SCAN HERE
const record: InstalledMarketplaceSkill = { ... };
```

We insert:

```typescript
await runGitCloneSubset(repository, gitRef, skillPath, targetDir);

const validSkill = await fs.stat(skillDoc).then((s) => s.isFile()).catch(() => false);
if (!validSkill) { ... }

// NEW: Security scan
const { scanSkill } = await import("./skill-security.js");
const scanReport = await scanSkill(targetDir);

// Save scan report alongside skill
await fs.writeFile(
  path.join(targetDir, ".scan-results.json"),
  JSON.stringify(scanReport, null, 2),
  "utf-8"
);

if (scanReport.status === "blocked") {
  await fs.rm(targetDir, { recursive: true, force: true });
  throw new Error(`Skill blocked by security scan: ${scanReport.findings.map(f => f.message).join(", ")}`);
}

const record: InstalledMarketplaceSkill = {
  ...existingFields,
  scanStatus: scanReport.status,  // NEW field
  scanReport,                      // NEW field
};
```

### 1.5 Scan Report Storage

**Where to persist scan results:** Next to the skill itself as `.scan-results.json`.

```
skills/
  weather/
    SKILL.md
    .scan-results.json     <-- NEW
  .marketplace/
    some-skill/
      SKILL.md
      .scan-results.json   <-- NEW
```

Why this approach:
- Travels with the skill (no separate database to sync)
- Easy to read from any consumer (API, UI, agent)
- Can be re-scanned and overwritten
- Filtered by `.` prefix (won't be loaded as skill content)
- Follows the pattern already used by `.cache/` directory

**For in-memory storage** (MemorySkillStore), store in the SkillPackage's files map as a virtual file.

### 1.6 Scan Acknowledgment System

When a skill has `status: "warning"` or `status: "critical"`, it should start **disabled** and require user acknowledgment before it can be enabled.

**Storage:** Add to the existing skill preferences in the database cache:

```typescript
// Extend the existing SkillPreferencesMap concept
type SkillPreferencesMap = Record<string, boolean>;

// NEW: Add acknowledgment tracking
type SkillAcknowledgmentMap = Record<string, {
  acknowledgedAt: string;
  acknowledgedFindings: number;  // How many findings were present at ack time
}>;

const SKILL_ACK_CACHE_KEY = "milaidy:skill-acknowledgments";
```

**Flow:**
1. Skill installs with findings -> scan report saved -> skill starts disabled
2. User sees skill in UI with warning badge -> clicks "Review Findings"
3. UI shows scan report -> user clicks "Acknowledge & Enable"
4. API saves acknowledgment + enables skill
5. If skill is re-scanned (updated), acknowledgment is invalidated if finding count changes

**API endpoint:**

```
POST /api/skills/:id/acknowledge
Body: { enable: boolean }
```

This uses the existing `PUT /api/skills/:id` (toggle) endpoint pattern but adds the acknowledgment step. The toggle endpoint should check: if skill has unacknowledged findings, reject enable requests.

### 1.7 Testing Strategy for Security

**Unit tests for the scanner** (adapt from `openclaw/src/security/skill-scanner.test.ts`):

```
plugins/plugin-agent-skills/typescript/src/security/
  skill-scanner.ts          <-- Core scanner (adapted from openclaw)
  skill-scanner.test.ts     <-- Tests
  markdown-scanner.ts       <-- Markdown-specific rules
  markdown-scanner.test.ts
  manifest-scanner.ts       <-- File tree validation
  manifest-scanner.test.ts
  index.ts                  <-- Unified scanSkill() export
```

Test cases:
- Clean skill -> `status: "clean"`
- Skill with `eval()` in script -> `status: "critical"`, finding for `dynamic-code-execution`
- Skill with `curl | bash` in SKILL.md -> `status: "critical"`, finding for `md-pipe-to-shell`
- Skill with binary `.exe` file -> `status: "blocked"`
- Skill with symlink -> `status: "blocked"`
- Skill with external URL in markdown -> `status: "warning"`
- Skill with env var reference -> `status: "warning"`
- Empty/missing SKILL.md -> `status: "blocked"`
- Large base64 payload -> `status: "warning"` for obfuscation

**Integration tests:**
- Install from catalog with clean skill -> skill is enabled
- Install from catalog with critical skill -> skill is disabled, scan report saved
- Install blocked skill -> install rejected, files cleaned up
- Acknowledge + enable a warning skill -> skill becomes enabled
- Re-scan after update -> acknowledgment invalidated

---

## Part 2: Skill Enable/Disable

### 2.1 Current State (Already Working)

The enable/disable system is fully implemented and well-designed:

- **Backend:** `resolveSkillEnabled()` in `milaidy/src/api/server.ts` lines 786-810 with 5-level priority chain
- **Database:** `runtime.getCache/setCache` with key `milaidy:skill-preferences`
- **API:** `PUT /api/skills/:id` with `{ enabled: boolean }` body
- **UI:** Toggle switch per skill in the Skills tab

### 2.2 What Needs to Change

**Only one change needed:** The `PUT /api/skills/:id` handler must check scan acknowledgment before allowing enable.

Currently (lines 3939-3964):
```typescript
if (body.enabled !== undefined) {
  skill.enabled = body.enabled;
  // ... persist
}
```

Change to:
```typescript
if (body.enabled === true) {
  // Check if skill has unacknowledged findings
  const scanReport = await loadScanReport(skillId, workspaceDir);
  if (scanReport && (scanReport.status === "critical" || scanReport.status === "warning")) {
    const acks = await loadSkillAcknowledgments(state.runtime);
    if (!acks[skillId]) {
      error(res, `Skill "${skillId}" has security findings that must be acknowledged before enabling. Use POST /api/skills/${skillId}/acknowledge.`, 409);
      return;
    }
  }
}
skill.enabled = body.enabled;
```

### 2.3 Agent-Side Enable/Disable

The agent currently has NO action to toggle skills. Add one:

**File: `plugins/plugin-agent-skills/typescript/src/actions/toggle-skill.ts`** (NEW)

```typescript
export const toggleSkillAction: Action = {
  name: "TOGGLE_SKILL",
  similes: ["ENABLE_SKILL", "DISABLE_SKILL", "TURN_ON_SKILL", "TURN_OFF_SKILL"],
  description: "Enable or disable an installed skill. Provide skill slug and desired state.",

  validate: async (runtime: IAgentRuntime, _message: Memory): Promise<boolean> => {
    const service = runtime.getService<AgentSkillsService>("AGENT_SKILLS_SERVICE");
    return !!service;
  },

  handler: async (runtime, message, _state, options, callback): Promise<ActionResult> => {
    // Extract slug and desired state from message/options
    // Call service method to toggle
    // Respect acknowledgment requirements
    // Return result
  },
};
```

This follows the exact same pattern as the existing 5 actions (validate checks service exists, handler extracts params from message/options, calls service, returns via callback).

Register in `plugin.ts` alongside existing actions:
```typescript
const ALL_ACTIONS: Action[] = [
  searchSkillsAction,
  getSkillDetailsAction,
  getSkillGuidanceAction,
  syncCatalogAction,
  runSkillScriptAction,
  toggleSkillAction,         // NEW
];
```

**Why this is the right approach:** The agent already uses `AgentSkillsService` for everything skill-related. Adding a toggle method to the service and an action to expose it follows the established pattern exactly. No new services, no new providers needed.

### 2.4 UI Enhancement for Enable/Disable

The current toggle is functional but doesn't show WHY a skill is disabled. Enhance the skill card:

```typescript
// In renderSkills(), for each skill:
${scanReport?.status === "critical"
  ? html`<span class="badge critical">Security: Critical</span>`
  : scanReport?.status === "warning"
    ? html`<span class="badge warning">Security: Review</span>`
    : ""}
```

And if the user tries to toggle a skill with unacknowledged findings, show the findings instead of toggling.

---

## Part 3: Skill Creation

### 3.1 Approach Analysis

**Approach A: Full in-app editor**

Build a SKILL.md editor in the UI with YAML frontmatter form fields and a markdown editor for instructions.

- Pros: Fully integrated, no context switch
- Cons: Huge effort, reinventing a text editor, frontmatter schema maintenance, markdown editing is hard in browsers
- Complexity: Very High

**Approach B: Template scaffold + open in editor**

Create the skill folder from a template, then open it in the user's preferred editor (VS Code, Cursor, etc.) or reveal in file manager.

- Pros: Minimal code, leverages existing tools, users edit in their preferred editor, skill-creator SKILL.md template already exists
- Cons: Requires leaving the app momentarily
- Complexity: Low

**Approach C: Hybrid -- form for metadata, editor for instructions**

A simple form in the UI for name + description (the required frontmatter), which scaffolds the folder. Then a "Edit Instructions" button that opens the file.

- Pros: Guided creation for the easy parts, real editor for the hard part
- Cons: Still needs external editor for the main content
- Complexity: Low-Medium

**Recommendation: Approach C (hybrid)**

This gives the user the best experience for the structured parts (name, description) while not trying to replace a real text editor for markdown authoring. It matches how the user described it: "create a new skill from a template, and if we edit a skill, it'll open the skill folder."

### 3.2 Implementation

**New API endpoint:**

```
POST /api/skills/create
Body: { name: string, description: string }
Response: { ok: true, skill: SkillEntry, path: string }
```

**Backend logic** (add to `milaidy/src/api/server.ts`):

```typescript
if (method === "POST" && pathname === "/api/skills/create") {
  const body = await readJsonBody<{ name: string; description: string }>(req, res);
  if (!body?.name?.trim()) {
    error(res, "Skill name is required", 400);
    return;
  }

  const workspaceDir = state.config.agents?.defaults?.workspace
    ?? resolveDefaultAgentWorkspaceDir();
  const skillsDir = path.join(workspaceDir, "skills");
  const slug = body.name.trim().toLowerCase().replace(/[^a-z0-9-]/g, "-").replace(/-+/g, "-");
  const skillDir = path.join(skillsDir, slug);

  if (fs.existsSync(skillDir)) {
    error(res, `Skill "${slug}" already exists`, 409);
    return;
  }

  await fs.promises.mkdir(skillDir, { recursive: true });

  const template = `---
name: ${slug}
description: ${body.description.trim().replace(/"/g, '\\"')}
---

## Instructions

[Describe what this skill does and how the agent should use it]

## When to Use

Use this skill when [describe trigger conditions].

## Steps

1. [First step]
2. [Second step]
3. [Third step]
`;

  await fs.promises.writeFile(path.join(skillDir, "SKILL.md"), template, "utf-8");

  // Refresh skills list
  state.skills = await discoverSkills(workspaceDir, state.config, state.runtime);
  const skill = state.skills.find(s => s.id === slug);

  json(res, { ok: true, skill, path: skillDir });
}
```

**Template source:** The template above is derived from the existing `openclaw/skills/skill-creator/SKILL.md` guidance, simplified to the minimum viable skill. It uses the YAML frontmatter format from the AgentSkills.io spec with just the two required fields (`name`, `description`).

### 3.3 Open Skill Folder / Edit Skill

**New API endpoint:**

```
POST /api/skills/:id/open
Response: { ok: true, path: string }
```

**Backend logic:**

```typescript
if (method === "POST" && pathname.match(/^\/api\/skills\/[^/]+\/open$/)) {
  const skillId = decodeURIComponent(pathname.split("/")[3]);
  
  // Find skill path from loaded skills
  const skillPath = await resolveSkillPath(skillId, workspaceDir, state.runtime);
  if (!skillPath) {
    error(res, `Skill "${skillId}" not found`, 404);
    return;
  }

  // Open in system file manager
  const { exec } = await import("node:child_process");
  const command = process.platform === "darwin"
    ? `open "${skillPath}"`
    : process.platform === "win32"
      ? `explorer "${skillPath}"`
      : `xdg-open "${skillPath}"`;

  exec(command, (err) => {
    if (err) logger.warn(`Failed to open skill folder: ${err.message}`);
  });

  json(res, { ok: true, path: skillPath });
}
```

**For Electron/Capacitor:** The desktop app can use the native `shell.openPath()` API instead of exec, which is safer. The `apps/app/electron/` directory already has Electron integration, so this can be enhanced there.

### 3.4 Agent-Side Skill Creation

The agent already has access to the `skill-creator` skill (bundled in OpenClaw). This skill provides detailed guidance for creating skills. However, the agent currently cannot create files in the workspace skills directory.

**Option A:** Add a `CREATE_SKILL` action that calls the same `POST /api/skills/create` logic internally.

**Option B:** Let the agent use its existing file-writing capabilities (if it has Bash/Write access) guided by the skill-creator skill.

**Recommendation: Option A** -- a dedicated action is safer because it validates the name format, prevents overwriting, and ensures the correct directory.

---

## Part 4: Skill Editing & Deletion

### 4.1 Editing

**The user said:** "if we edit a skill, it'll open the skill folder, and we can edit the skill just from wherever we are."

This is the `POST /api/skills/:id/open` endpoint from Part 3.3. For non-workspace skills (bundled, managed), we need to handle the "copy to workspace for editing" pattern:

```typescript
// In the /open handler:
if (skillSource === "bundled" || skillSource === "managed") {
  // Copy to workspace so user can override
  const workspaceSkillDir = path.join(workspaceDir, "skills", skillId);
  if (!fs.existsSync(workspaceSkillDir)) {
    await fs.promises.cp(skillPath, workspaceSkillDir, { recursive: true });
  }
  // Open the workspace copy
  skillPath = workspaceSkillDir;
}
```

This leverages the existing precedence system: workspace skills (precedence 5) override bundled skills (precedence 3). The user edits the workspace copy; the original bundled skill is untouched.

### 4.2 Deletion

**New API endpoint:**

```
DELETE /api/skills/:id
Response: { ok: true }
```

**Logic:**
- Workspace skills: Delete the folder from `{workspaceDir}/skills/{id}/`
- Marketplace skills: Call existing `uninstallMarketplaceSkill()`
- Catalog-installed skills: Call existing `service.uninstall()`
- Bundled skills: Cannot delete (return 403)

**UI:** Add a delete button (with confirmation) to skill cards for non-bundled skills.

---

## Part 5: ClawHub Integration with Security

### 5.1 Current Integration

ClawHub is already the default registry:
- `AgentSkillsService` uses `apiBase: "https://clawhub.ai"` by default
- Catalog syncs hourly via `syncCatalog()`
- Search via `/api/v1/search` with vector embeddings
- Install via `/api/v1/download?slug=:slug&version=:version`
- Configurable via `SKILLS_REGISTRY` env var

### 5.2 What Needs to Change for Security

With the scanner wired into the install path (Part 1), **every ClawHub install automatically goes through scanning**. No additional ClawHub-specific code is needed for the basic security flow.

However, we should add **pre-install trust signals** from ClawHub metadata:

**Enhance the catalog/details display** to show trust indicators:

```typescript
// In GET /api/skills/catalog and GET /api/skills/catalog/:slug responses,
// add trust signals from ClawHub metadata:
{
  slug: "weather-pro",
  displayName: "Weather Pro",
  // ... existing fields ...
  trustSignals: {                        // NEW
    registryAge: "2025-11-15",           // When first published
    stars: 42,                           // ClawHub stars
    downloads: 1250,                     // Download count
    ownerAccountAge: "2024-03-01",       // Publisher GitHub account creation date
    hasSourceRepo: true,                 // Whether source GitHub repo is linked
    lastUpdated: "2026-01-20",           // Last update date
    // Computed score:
    trustLevel: "moderate",              // "untrusted" | "low" | "moderate" | "high"
  }
}
```

**Trust level computation** (local, not from ClawHub -- we compute this ourselves):

```typescript
function computeTrustLevel(entry: SkillCatalogEntry): "untrusted" | "low" | "moderate" | "high" {
  let score = 0;

  // Age signals
  const ageMs = Date.now() - entry.createdAt;
  if (ageMs > 90 * 24 * 3600000) score += 3;      // > 90 days
  else if (ageMs > 30 * 24 * 3600000) score += 2;  // > 30 days
  else if (ageMs > 7 * 24 * 3600000) score += 1;   // > 7 days

  // Popularity signals
  if (entry.stats.stars >= 20) score += 3;
  else if (entry.stats.stars >= 5) score += 2;
  else if (entry.stats.stars >= 1) score += 1;

  if (entry.stats.downloads >= 100) score += 2;
  else if (entry.stats.downloads >= 10) score += 1;

  // Source signals
  if (entry.sourceUrl?.includes("github.com")) score += 1;

  if (score >= 8) return "high";
  if (score >= 5) return "moderate";
  if (score >= 2) return "low";
  return "untrusted";
}
```

**UI indicator:** Show trust level badge next to install button in the catalog browser. "Untrusted" skills get a red warning, "low" gets yellow, etc.

### 5.3 ClawHub-Specific Scanner Enhancement

Since ClawHub had the specific attack pattern of malicious URLs in markdown instructions, we should have a ClawHub-aware scanner rule:

```typescript
{
  ruleId: "md-clawhub-known-attack",
  severity: "critical",
  message: "URL matches known ClawHub malware distribution pattern",
  // This would be a dynamic list, fetched from a maintained allowlist/blocklist
  pattern: null,  // Uses dynamic check instead
  check: (content: string) => checkAgainstKnownBadUrls(content),
}
```

The `checkAgainstKnownBadUrls` function would:
1. Extract all URLs from the markdown
2. Check against a local blocklist (shipped with the app, updated periodically)
3. Flag any matches as CRITICAL

---

## Part 6: Unified Skill Manager UI

### 6.1 Current UI Structure

The Skills tab in `renderSkills()` (lines 5451-5631 of `app.ts`) currently has:
1. API key config section (for SkillsMP)
2. Marketplace section (search + GitHub URL install + installed list + results)
3. Loaded skills list (with toggle)

### 6.2 Proposed UI Restructure

Keep the existing code but reorganize into clear sections with tab-like sub-navigation:

```
Skills Tab
  Sub-tabs: [My Skills] [Browse & Install] [Security Review]

  [My Skills] (default)
    [+ New Skill] button
    Skill cards:
      - Name, description
      - Source badge (workspace / bundled / catalog / marketplace)
      - Security badge (if applicable)
      - Toggle switch
      - [Edit] [Delete] buttons (for workspace/installed skills)

  [Browse & Install]
    Search bar (searches ClawHub catalog + SkillsMP simultaneously)
    Source filter: [All] [ClawHub] [SkillsMP]
    GitHub URL install input
    Results with trust badges and [Install] buttons

  [Security Review]
    Skills with unacknowledged findings
    For each: findings list, [Acknowledge & Enable] or [Remove] buttons
    Scan history
```

### 6.3 Implementation Approach

Rather than a full restructure of the monolithic `renderSkills()`, add the sub-tab state and conditional rendering:

```typescript
@state() skillsSubTab: "my" | "browse" | "review" = "my";
```

Then split the existing `renderSkills()` into three sub-methods:
- `renderMySkills()` -- existing loaded skills list + create/edit/delete
- `renderBrowseSkills()` -- existing marketplace section + catalog browser
- `renderSecurityReview()` -- new, shows skills with scan findings

This keeps the existing code intact and adds incrementally.

### 6.4 New State Variables

```typescript
@state() skillScanReports: Record<string, SkillScanReport> = {};
@state() skillAcknowledgments: Record<string, boolean> = {};
@state() skillCreating = false;
@state() skillCreateName = "";
@state() skillCreateDescription = "";
```

### 6.5 New API Client Methods

Add to `api-client.ts`:

```typescript
async createSkill(name: string, description: string) { ... }
async openSkill(skillId: string) { ... }
async deleteSkill(skillId: string) { ... }
async getSkillScanReport(skillId: string) { ... }
async acknowledgeSkill(skillId: string, enable: boolean) { ... }
```

---

## Part 7: Agent-Side Skill Self-Management

### 7.1 Current Agent Capabilities

The agent currently has these skill actions:
1. `SEARCH_SKILLS` -- Search registry
2. `GET_SKILL_DETAILS` -- Get info about a specific skill
3. `GET_SKILL_GUIDANCE` -- Auto-find, install, and return instructions (this already auto-installs!)
4. `SYNC_SKILL_CATALOG` -- Refresh catalog
5. `RUN_SKILL_SCRIPT` -- Execute bundled scripts

And these providers:
1. `skillsSummaryProvider` -- All installed skills (always in context)
2. `skillInstructionsProvider` -- Relevant skill instructions (contextual)
3. `catalogAwarenessProvider` -- Catalog categories (when asked about capabilities)

### 7.2 What's Missing

The agent CANNOT:
- Enable/disable skills
- Install skills explicitly (only implicitly via GET_SKILL_GUIDANCE)
- Uninstall skills
- See scan results
- Create skills
- See which skills are enabled vs disabled

### 7.3 New Actions Needed

**1. `TOGGLE_SKILL`** (covered in Part 2.3)

**2. `INSTALL_SKILL`** -- Explicit install from registry or marketplace:

```typescript
export const installSkillAction: Action = {
  name: "INSTALL_SKILL",
  similes: ["DOWNLOAD_SKILL", "ADD_SKILL", "GET_SKILL"],
  description: "Install a skill from the registry or marketplace. Provide skill slug or search term.",

  handler: async (runtime, message, _state, options, callback) => {
    // 1. Extract slug from options/message
    // 2. Call service.install(slug)
    // 3. Check scan results
    // 4. If clean: report success
    // 5. If warning/critical: report findings, skill starts disabled
    // 6. If blocked: report rejection
  },
};
```

**3. `UNINSTALL_SKILL`**:

```typescript
export const uninstallSkillAction: Action = {
  name: "UNINSTALL_SKILL",
  similes: ["REMOVE_SKILL", "DELETE_SKILL"],
  description: "Uninstall a non-bundled skill. Cannot remove bundled skills.",
  // ...
};
```

**4. Enhanced `skillsSummaryProvider`** -- Include enabled/disabled status:

Currently, the provider calls `generateSkillsPromptXml()`. Enhance to include:

```xml
<skill name="weather" description="..." enabled="true" source="bundled"/>
<skill name="risky-tool" description="..." enabled="false" source="catalog" scan-status="warning"/>
```

This lets the agent see at a glance which skills are on/off and whether any have security concerns.

### 7.4 Agent Autonomy Boundaries

The agent SHOULD be able to:
- Search and browse skills
- Install skills (they go through scanning automatically)
- Enable/disable skills that are clean
- View scan results

The agent SHOULD NOT be able to:
- Enable skills with unacknowledged findings (same restriction as the API)
- Bypass the scanner
- Delete workspace skills without confirmation

This is enforced at the `AgentSkillsService` level, not at the action level. The service's toggle method checks acknowledgments.

---

## Part 8: Complete File Change List

### New Files

| File | Purpose | Lines (est.) |
|---|---|---|
| `plugins/plugin-agent-skills/typescript/src/security/index.ts` | Unified `scanSkill()` export | ~30 |
| `plugins/plugin-agent-skills/typescript/src/security/skill-scanner.ts` | Code scanner (adapted from openclaw) | ~250 |
| `plugins/plugin-agent-skills/typescript/src/security/markdown-scanner.ts` | SKILL.md content scanner | ~120 |
| `plugins/plugin-agent-skills/typescript/src/security/manifest-scanner.ts` | File tree validation | ~100 |
| `plugins/plugin-agent-skills/typescript/src/security/types.ts` | Scan report types | ~50 |
| `plugins/plugin-agent-skills/typescript/src/security/skill-scanner.test.ts` | Scanner tests | ~200 |
| `plugins/plugin-agent-skills/typescript/src/security/markdown-scanner.test.ts` | Markdown scanner tests | ~150 |
| `plugins/plugin-agent-skills/typescript/src/security/manifest-scanner.test.ts` | Manifest scanner tests | ~100 |
| `plugins/plugin-agent-skills/typescript/src/actions/toggle-skill.ts` | Agent toggle action | ~80 |
| `plugins/plugin-agent-skills/typescript/src/actions/install-skill.ts` | Agent explicit install action | ~100 |
| `plugins/plugin-agent-skills/typescript/src/actions/uninstall-skill.ts` | Agent uninstall action | ~70 |

### Modified Files

| File | Change | Impact |
|---|---|---|
| `plugins/plugin-agent-skills/typescript/src/services/skills.ts` | Add scan call in `install()`, `installFromUrl()`, `installFromGitHub()`. Add `saveScanReport()`, `loadScanReport()`, `skillScanFlags` map. Add `toggleSkill()` method. | Medium -- 3 insertion points + 3 new methods |
| `plugins/plugin-agent-skills/typescript/src/plugin.ts` | Register 3 new actions | Trivial |
| `plugins/plugin-agent-skills/typescript/src/types.ts` | Add `SkillScanReport` type, extend `LoadedSkillWithSource` with optional `scanStatus` | Small |
| `milaidy/src/services/skill-marketplace.ts` | Add scan call in `installMarketplaceSkill()`, extend `InstalledMarketplaceSkill` with `scanStatus` | Small -- 1 insertion point |
| `milaidy/src/api/server.ts` | Add `POST /api/skills/create`, `POST /api/skills/:id/open`, `POST /api/skills/:id/acknowledge`, `DELETE /api/skills/:id`, `GET /api/skills/:id/scan`. Modify `PUT /api/skills/:id` to check acknowledgment. | Medium -- 5 new endpoints + 1 modified |
| `milaidy/apps/ui/src/ui/app.ts` | Add skills sub-tabs, create modal, security review section, edit/delete buttons, scan badges | Medium -- extending existing `renderSkills()` |
| `milaidy/apps/ui/src/ui/api-client.ts` | Add 5 new API client methods | Small |

### Files NOT Changed

- `openclaw/src/security/skill-scanner.ts` -- Not modified. We adapt its patterns into the plugin package to avoid cross-dependency.
- `openclaw/src/agents/skills-install.ts` -- Not modified. OpenClaw's install path is separate from Milaidy's.
- `plugins/plugin-agent-skills/typescript/src/storage.ts` -- Not modified. Scan reports are stored as files, not through the storage abstraction.
- `plugins/plugin-agent-skills/typescript/src/parser.ts` -- Not modified. Parsing is already correct.

---

## Part 9: Implementation Order

### Phase 1: Security Foundation (do first, most critical)

**Step 1.1:** Create scanner module
- New files: `security/types.ts`, `security/skill-scanner.ts`, `security/markdown-scanner.ts`, `security/manifest-scanner.ts`, `security/index.ts`
- Adapt code patterns from `openclaw/src/security/skill-scanner.ts`
- Add markdown-specific rules for the Feb 2026 attack patterns
- Add manifest validation

**Step 1.2:** Write scanner tests
- New files: All `*.test.ts` files in `security/`
- Create test fixtures: clean skill, malicious skill, borderline skill
- Verify each rule fires correctly
- Verify severity rollup logic

**Step 1.3:** Wire scanner into AgentSkillsService install paths
- Modify: `services/skills.ts` -- add scan after save, before load
- Add: `saveScanReport()`, `loadScanReport()` methods
- Add: `skillScanFlags` map for in-memory tracking
- Blocked skills are rejected and cleaned up

**Step 1.4:** Wire scanner into marketplace install
- Modify: `skill-marketplace.ts` -- add scan after clone, before record creation
- Blocked skills are rejected and cleaned up

### Phase 2: Acknowledgment System

**Step 2.1:** Add acknowledgment storage and API
- Modify: `server.ts` -- add `POST /api/skills/:id/acknowledge` endpoint
- Modify: `server.ts` -- add acknowledgment check in `PUT /api/skills/:id`
- Add acknowledgment persistence using existing cache pattern

**Step 2.2:** Add scan report API
- Modify: `server.ts` -- add `GET /api/skills/:id/scan` endpoint
- Returns scan report from `.scan-results.json` file

### Phase 3: Agent Actions

**Step 3.1:** Add toggle-skill action
- New file: `actions/toggle-skill.ts`
- Modify: `plugin.ts` -- register action

**Step 3.2:** Add install-skill and uninstall-skill actions
- New files: `actions/install-skill.ts`, `actions/uninstall-skill.ts`
- Modify: `plugin.ts` -- register actions

**Step 3.3:** Enhance providers
- Modify: `skillsSummaryProvider` to include enabled/disabled status and scan status

### Phase 4: Skill Creation & Editing

**Step 4.1:** Add create endpoint
- Modify: `server.ts` -- add `POST /api/skills/create`

**Step 4.2:** Add open/edit endpoint
- Modify: `server.ts` -- add `POST /api/skills/:id/open`
- Handle bundled skill copy-to-workspace

**Step 4.3:** Add delete endpoint
- Modify: `server.ts` -- add `DELETE /api/skills/:id`
- Route to appropriate deletion method based on source

### Phase 5: UI Enhancements

**Step 5.1:** Add sub-tab navigation to Skills tab
**Step 5.2:** Add security review section
**Step 5.3:** Add create skill modal
**Step 5.4:** Add edit/delete buttons to skill cards
**Step 5.5:** Add scan status badges
**Step 5.6:** Add trust level badges in catalog browser

---

## Part 10: Testing Plan

### Unit Tests

| Test Suite | What it Covers |
|---|---|
| `skill-scanner.test.ts` | Code pattern detection (JS/TS files) |
| `markdown-scanner.test.ts` | Markdown content scanning (SKILL.md) |
| `manifest-scanner.test.ts` | File tree validation |
| `toggle-skill.test.ts` | Toggle action handler |
| `install-skill.test.ts` | Install action handler |

### Integration Tests

| Test | What it Covers |
|---|---|
| Install clean skill from catalog | Full flow: download -> scan -> load -> enabled |
| Install warning skill from catalog | Full flow: download -> scan -> load -> disabled |
| Install blocked skill from catalog | Full flow: download -> scan -> reject -> cleanup |
| Install from marketplace with findings | Full flow: clone -> scan -> record with status |
| Acknowledge and enable | Full flow: review -> acknowledge -> enable |
| Agent toggle skill | Full flow: action -> service -> preference persist |
| Create skill from template | Full flow: API -> scaffold -> discover -> return |
| Delete workspace skill | Full flow: API -> delete files -> re-discover |
| Re-scan after update | Full flow: update -> re-scan -> invalidate ack if changed |

### Manual Testing Checklist

- [ ] Install a clean skill from ClawHub catalog via UI -> appears enabled
- [ ] Install a skill with external URLs in SKILL.md -> appears disabled with warning badge
- [ ] Try to toggle a warning skill without acknowledging -> get error message
- [ ] Acknowledge a warning skill -> can now enable
- [ ] Create a new skill via UI -> folder created, skill appears in list
- [ ] Click "Edit" on a skill -> folder opens in Finder/Explorer
- [ ] Click "Edit" on a bundled skill -> copied to workspace, workspace copy opens
- [ ] Delete a workspace skill -> removed from list
- [ ] Try to delete a bundled skill -> get error message
- [ ] Agent asks "what skills do I have?" -> sees list with enabled/disabled status
- [ ] Agent says "enable the weather skill" -> skill toggles
- [ ] Agent says "install the github skill" -> installs with scan
- [ ] Search for skills in Browse tab -> results from both ClawHub and SkillsMP

---

## Appendix A: Type Definitions (New)

```typescript
// plugins/plugin-agent-skills/typescript/src/security/types.ts

export type SkillScanSeverity = "info" | "warn" | "critical";

export interface SkillScanFinding {
  ruleId: string;
  severity: SkillScanSeverity;
  file: string;
  line: number;
  message: string;
  evidence: string;
}

export interface ManifestFinding {
  ruleId: string;
  severity: SkillScanSeverity;
  file: string;
  message: string;
}

export type SkillScanStatus = "clean" | "warning" | "critical" | "blocked";

export interface SkillScanReport {
  scannedAt: string;
  status: SkillScanStatus;
  summary: {
    scannedFiles: number;
    critical: number;
    warn: number;
    info: number;
  };
  findings: SkillScanFinding[];
  manifestFindings: ManifestFinding[];
  skillPath: string;
}
```

## Appendix B: Markdown Scanner Rules (Complete)

```typescript
// plugins/plugin-agent-skills/typescript/src/security/markdown-scanner.ts

const MARKDOWN_LINE_RULES: Array<{
  ruleId: string;
  severity: SkillScanSeverity;
  message: string;
  pattern: RegExp;
}> = [
  // CRITICAL: Active exploitation patterns (seen in Feb 2026 ClawHub attacks)
  {
    ruleId: "md-pipe-to-shell",
    severity: "critical",
    message: "Pipe-to-shell pattern (common malware vector)",
    pattern: /\|\s*(ba)?sh\b|\|\s*sudo\b|\|\s*python[23]?\b/,
  },
  {
    ruleId: "md-curl-exec",
    severity: "critical",
    message: "Download-and-execute pattern",
    pattern: /curl\s+[^\n]*\|\s*(ba)?sh|wget\s+[^\n]*\|\s*(ba)?sh/i,
  },
  {
    ruleId: "md-prompt-injection",
    severity: "critical",
    message: "Prompt injection -- instruction override attempt",
    pattern: /ignore\s+(all\s+)?(previous|prior|above|earlier)\s+(instructions|rules|guidelines|context)/i,
  },
  {
    ruleId: "md-credential-send",
    severity: "critical",
    message: "Instruction to exfiltrate credentials",
    pattern: /send\s+(the\s+)?(api[_\s-]?key|token|secret|password|credential|private[_\s-]?key)\s+(to|via|using|over)\b/i,
  },
  {
    ruleId: "md-base64-decode-exec",
    severity: "critical",
    message: "Base64 decode and execute pattern",
    pattern: /base64\s+(--)?decode?\b.*\|\s*(ba)?sh|echo\s+[A-Za-z0-9+/=]{50,}\s*\|\s*base64/i,
  },
  {
    ruleId: "md-hidden-command",
    severity: "critical",
    message: "Zero-width or invisible characters hiding content",
    pattern: /[\u200B\u200C\u200D\uFEFF\u2060]/,
  },

  // WARN: Suspicious but potentially legitimate
  {
    ruleId: "md-external-url",
    severity: "warn",
    message: "External URL (not a known-safe domain)",
    pattern: /https?:\/\/(?!(github\.com|raw\.githubusercontent\.com|clawhub\.(ai|com)|skillsmp\.com|agentskills\.io|npmjs\.(com|org)|pypi\.org|docs\.rs|crates\.io|pkg\.go\.dev|brew\.sh|wttr\.in)\b)[a-zA-Z0-9][^\s)\]"'<>]*/,
  },
  {
    ruleId: "md-env-credential",
    severity: "warn",
    message: "References sensitive environment variable",
    pattern: /\$\{?\w*(API[_-]?KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|PRIVATE[_-]?KEY|AUTH)\w*\}?/i,
  },
  {
    ruleId: "md-system-path-write",
    severity: "warn",
    message: "References writing to system paths",
    pattern: />\s*\/etc\/|>\s*\/usr\/|>\s*~\/\.|>\s*\/tmp\//,
  },
  {
    ruleId: "md-npm-global-install",
    severity: "warn",
    message: "Global package install instruction",
    pattern: /npm\s+i(nstall)?\s+(-g|--global)\b|pnpm\s+add\s+(-g|--global)\b/,
  },
  {
    ruleId: "md-chmod-exec",
    severity: "warn",
    message: "Makes file executable",
    pattern: /chmod\s+\+x\b|chmod\s+[0-7]*[1357][0-7]*\b/,
  },
];
```

## Appendix C: Decision Log

| Decision | Chosen | Rejected | Rationale |
|---|---|---|---|
| Quarantine approach | Scan-on-install + acknowledgment gate | Physical quarantine folder | Uses existing enable/disable, no folder moves, less state to manage |
| Scanner location | New module in plugin-agent-skills | Import from openclaw | Avoids cross-dependency between Milaidy and OpenClaw packages |
| Enable/disable storage | Keep config-based (existing) | Physical enabled/disabled folders | Already works, supports per-agent, handles bundled skills |
| Skill editing | Open folder in system editor | In-app markdown editor | Much less code, better editing experience, user's preferred tools |
| Skill creation | Template scaffold + form | Full in-app editor | Guided for metadata, real editor for instructions |
| Scan report storage | `.scan-results.json` next to skill | Database table | Travels with skill, no schema migration, easy to read |
| Agent toggle | New action + service method | Direct database manipulation | Follows existing action pattern, respects acknowledgment rules |
| Trust scoring | Local computation from catalog metadata | ClawHub-provided score | ClawHub has no trust system; we compute our own |
