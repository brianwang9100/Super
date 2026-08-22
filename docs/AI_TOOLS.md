# Super: AI Development Tools

> Evaluation of AI-assisted development tools for building Super, with security assessments.

---

## 1. Purpose

This document evaluates AI development tools that could accelerate Super's development. Each tool is assessed for functionality, Swift/iOS relevance, security posture, and fit within our autonomous AI-agent workflow (see [CI_PIPELINE.md](./CI_PIPELINE.md)).

---

## 2. Tool Summary

| Tool | Type | What It Does | License | Cost | Security Rating |
|------|------|-------------|---------|------|-----------------|
| **Axiom** | MCP server; legacy Claude Code plugin | Apple platform development skills, agents, and reference docs | MIT | Free | Good |
| **GSD (Get Shit Done)** | Legacy Claude workflow layer | Spec-driven planning/execution with fresh contexts per task | MIT | Free | Moderate (with caveats) |
| **Context7** | MCP server | Live library documentation injection into AI prompts | MIT (client) | Free tier / $10/mo Pro | Poor (recent vulnerability) |

---

## 3. Axiom

### 3.1 Overview

Axiom is a collection of **102 discipline skills, 50 reference skills, 22 diagnostic skills, 11 commands, and 38 agents** specifically built for Apple platform development (iOS, iPadOS, tvOS, watchOS, macOS). Created by Charles Wiltgen.

- **Repository:** [github.com/CharlesWiltgen/Axiom](https://github.com/CharlesWiltgen/Axiom)
- **Docs:** [charleswiltgen.github.io/Axiom](https://charleswiltgen.github.io/Axiom/)
- **License:** MIT (free, open source)
- **Current version:** v2.33.0

### 3.2 How It Works

Two integration modes are documented upstream:

1. **Claude Code Plugin (legacy):** Install via `/plugin marketplace add CharlesWiltgen/Axiom`. This is not part of Super's Codex project setup and must not create repository `.claude/` tooling.

2. **MCP Server:** TypeScript/Node.js MCP server using stdio transport. It may be evaluated as an additional Codex MCP only after dependency and network review; it is not a replacement for the checked-in XcodeBuild and iOS Simulator MCP servers.

Key capability: reads **Apple documentation directly from your local Xcode installation** at runtime — 20 official Apple guide topics and 32 Swift compiler diagnostics. Docs stay current with Xcode updates automatically.

### 3.3 Relevant Capabilities for Super

| Capability | Why It Matters for Super |
|-----------|---------------------------|
| Swift 6 concurrency patterns (actors, `@concurrent`, Sendable) | Event bus, cross-applet communication, GRDB threading |
| SwiftUI performance optimization | 60fps animation budget, complex list views |
| SwiftUI 26 reference (WebView, AttributedString, 3D charts) | Calendar visualizations, Chat chat rendering |
| Database schema migration (SQLite/GRDB) | Per-applet GRDB migration management |
| Xcode debugging & build dependency resolution | Monorepo with multiple Swift Packages |
| Memory leak diagnosis & Instruments profiling | Performance-critical animation engine |
| App Intents framework (Siri, Shortcuts) | Future Siri integration |
| Accessibility (WCAG, VoiceOver, Dynamic Type) | Accessibility audit in Phase 6 |
| Liquid Glass (iOS 26+) | Modern UI design |

### 3.4 Security Assessment

| Aspect | Finding |
|--------|---------|
| **Data sent externally** | None found. Runs locally via stdio transport. Reads from local Xcode installation. |
| **Network calls** | No external API calls, no telemetry detected in source code |
| **Filesystem access** | Reads Apple docs from Xcode bundle path (read-only). Skills are curated markdown/YAML. |
| **Dependencies** | Node.js MCP server — audit `package.json` before deploying |
| **Permission model** | Review the approval and sandbox model of the consuming agent before installation. |
| **Security policy** | None published — no formal "we don't send your data" declaration |
| **Source auditable** | Yes, fully open source MIT. MCP server source at `mcp-server/src/` |

**Verdict: Good.** Local-only, no network calls, open source, auditable. The only gap is the lack of a formal security policy, but the architecture itself is sound — it's fundamentally just curated reference material served locally.

**Recommendation: Evaluate the MCP form only when needed.** Do not install the legacy Claude Code plugin into this repository; Super's checked-in Codex configuration is the active contributor setup.

---

## 4. GSD (Get Shit Done)

### 4.1 Overview

GSD is a **meta-prompting and spec-driven development workflow** that sits on top of AI coding agents. It solves **context rot** — the quality degradation that happens as an LLM fills its context window during long sessions. GSD forces work into small, planned tasks, each running in a fresh 200k-token context window.

- **Repository:** [github.com/gsd-build/get-shit-done](https://github.com/gsd-build/get-shit-done)
- **Website:** [gsd.build](https://gsd.build/)
- **License:** MIT (free, open source)
- **Stars:** ~11.9K

### 4.2 How It Works

```
npx get-shit-done-cc@latest
```

Its legacy installer writes markdown, a Node.js helper, and hooks into `.claude/`. Do not run it in this repository: Codex-native instructions, hooks, and task workflow are already checked in.

**Workflow phases:**

```
  /gsd:discuss-phase         /gsd:plan-phase           /gsd:execute-phase        /gsd:verify-work
  ┌──────────────┐     ┌───────────────────┐     ┌────────────────────┐     ┌──────────────┐
  │   Discuss    │ ──► │      Plan         │ ──► │     Execute        │ ──► │    Verify    │
  │              │     │                   │     │                    │     │              │
  │ Capture      │     │ 4 parallel        │     │ Wave-based tasks   │     │ User         │
  │ decisions    │     │ researcher agents │     │ Fresh context each │     │ acceptance   │
  │ & specs      │     │ (Stack, Features, │     │ Atomic git commits │     │ testing      │
  │              │     │  Arch, Pitfalls)  │     │                    │     │              │
  └──────────────┘     └───────────────────┘     └────────────────────┘     └──────────────┘
```

Key architectural choices:
- Each task runs in a **fresh subagent context** — task 50 has the same quality as task 1
- **Wave-based parallel execution** with dependency awareness
- Inter-agent communication via **files on disk** (stateless, recoverable)
- All state stored in `.planning/` directory (PROJECT.md, REQUIREMENTS.md, ROADMAP.md, STATE.md)

### 4.3 Relevant Capabilities for Super

| Capability | Why It Matters for Super |
|-----------|---------------------------|
| Spec-driven planning (discuss → plan → execute → verify) | Matches our "one agent per applet" build strategy |
| Fresh context per task | Prevents degradation in complex multi-applet monorepo |
| Wave-based parallel execution | Multiple applets can be developed concurrently |
| Brownfield support (`/gsd:map-codebase`) | Useful once the project has existing code |
| 4-researcher planning pattern | Investigates best practices before each implementation phase |
| Atomic git commits per task | Clean history, easy to review in PRs |
| Session recovery via STATE.md | Resumable — doesn't lose progress on crash or context limit |

### 4.4 Security Assessment

| Aspect | Finding |
|--------|---------|
| **Data sent externally** | GSD itself makes no external API calls (beyond npm version checks). All processing is local and file-based. |
| **Data sent via underlying LLM** | The legacy runner uses Claude Code; this is not Super's active agent path. |
| **Filesystem access** | Reads the project, creates `.planning/` and `.claude/` files, and makes Git commits. |
| **`--dangerously-skip-permissions` recommendation** | **This is the primary concern.** The legacy workflow recommends disabling its agent's permission system. See details below. |
| **Source auditable** | Yes, fully open source MIT |
| **Security contact** | security@gsd.build |

**The `--dangerously-skip-permissions` Issue:**

GSD's documentation recommends `--dangerously-skip-permissions` to avoid manually approving each file operation, Git commit, or shell command. While it has safeguards (`allowed-tools` frontmatter, secret detection, sensitive file deny lists), the underlying concern is real:

- In January 2026, a developer lost ~11GB of files when Claude executed `rm -rf` with permissions skipped
- PromptArmor demonstrated that hidden text in documents could manipulate Claude into exfiltrating files via allowlisted APIs
- Security consensus: never run `--dangerously-skip-permissions` on your primary machine

**Mitigations we would apply:**

1. **Never use `--dangerously-skip-permissions` on the host machine.** Use default permission mode or granular `allowed-tools`.
2. Run GSD execution phases in **isolated environments** (Docker containers, VMs, or git worktrees)
3. Use GSD's planning phases (discuss/plan) interactively, then review specs before execution
4. Git checkpoints before each session allow `git reset` recovery

**Verdict: Moderate.** GSD itself is safe and well-designed. The risk comes from the operational recommendation to disable permissions. If we enforce our own permission policy (no `--dangerously-skip-permissions`), GSD is a valuable workflow tool.

**Recommendation: Do not install in Super.** Its Claude-specific repository writes conflict with the active Codex tooling. Its planning ideas remain useful as general reference, but the checked-in Codex workflow and safeguards are authoritative.

---

## 5. Context7

### 5.1 Overview

Context7 is a documentation delivery platform by Upstash that injects up-to-date, version-specific library documentation into AI coding assistant prompts via MCP. It indexes 9,000+ libraries.

- **Repository:** [github.com/upstash/context7](https://github.com/upstash/context7)
- **Website:** [context7.com](https://context7.com)
- **License:** MIT (MCP client); backend is proprietary
- **Stars:** ~49K

### 5.2 How It Works

MCP server exposes two tools:
- `resolve-library-id` — resolves a library name to a Context7 ID
- `get-library-docs` — retrieves documentation for a specific library with optional topic filtering

When you include "use context7" in a prompt, the MCP server fetches current documentation from **Context7's external servers** and injects it into the AI's context window.

### 5.3 Relevance for Swift/iOS Development

**Low.** Context7's strength is the JavaScript/TypeScript/web ecosystem (Next.js, Supabase, MongoDB). Swift/iOS coverage is minimal:

- A page exists for Swift at `context7.com/apple/swift`, but no evidence of deep SwiftUI, UIKit, Combine, or Apple framework indexing
- Third-party Swift libraries (Alamofire, GRDB, etc.) may not be indexed
- **Better Apple-specific alternatives exist:**
  - [apple-docs-mcp](https://github.com/kimsungwhee/apple-docs-mcp) — MCP server for Apple Developer Documentation (iOS/macOS/SwiftUI/UIKit/WWDC)
  - [llm.codes](https://steipete.me/posts/2025/llm-codes-transform-developer-docs) — by Peter Steinberger, purpose-built to make Apple docs AI-readable
  - **Axiom** (above) — reads docs directly from local Xcode installation

Context7 could be useful for our **backend** (TypeScript/Hono/Drizzle/Postgres ecosystem), but even there, it has security concerns.

### 5.4 Security Assessment

| Aspect | Finding |
|--------|---------|
| **Data sent externally** | **Yes.** Library search queries are sent to `context7.com` API. Context7 claims "only derived topics" are sent, not your code, but query content is transmitted. |
| **ContextCrush vulnerability (Feb 2026)** | **Critical.** Researchers demonstrated a three-stage attack via Context7's "Custom Rules" feature. See details below. |
| **Backend** | Proprietary — you cannot audit the server-side code |
| **Trust system** | Gameable — attackers earned "trending" badges via fake API requests |
| **Content verification** | No mechanism in MCP for AI agents to verify content authenticity |
| **Data leakage risk** | GitHub Issue #402 raised concern about confidential data in queries |

**The ContextCrush Vulnerability (February 2026):**

Discovered by Noma Security, this was a **proven, exploited prompt injection attack**:

1. An attacker registered a library on Context7 with poisoned "Custom Rules"
2. The rules instructed the AI to search for `.env` files containing credentials
3. The AI was directed to exfiltrate credentials to an attacker-controlled GitHub repository (via Issues API)
4. The AI then deleted local files under the guise of "cleanup"
5. The attacker gamed the trust system to appear as a "top 4%" contributor

**Timeline:** Discovered Feb 18, 2026 → Patched Feb 23, 2026 → Disclosed March 5, 2026.

The fix added rule sanitization, but the fundamental architecture concern remains: Context7 serves content from community contributors that the AI treats as trusted instructions.

**Verdict: Poor.** Recent critical vulnerability, queries sent to external servers, proprietary backend, gameable trust system. The risk/benefit ratio is unfavorable, especially given that better alternatives exist for both Swift (Axiom, apple-docs-mcp) and general documentation.

**Recommendation: Do not adopt.** The security concerns outweigh the benefits. For Swift/iOS docs, use Axiom. For backend TypeScript docs, rely on the LLM's training data or use official documentation directly.

---

## 6. Additional Tools Worth Considering

These were not specifically requested but surfaced during research as relevant for Super:

### 6.1 apple-docs-mcp

- **What:** MCP server for Apple Developer Documentation
- **Coverage:** iOS, macOS, SwiftUI, UIKit, WWDC session content
- **Repository:** [github.com/kimsungwhee/apple-docs-mcp](https://github.com/kimsungwhee/apple-docs-mcp)
- **Security:** Fetches from Apple's official documentation servers (developer.apple.com). No user data sent. Open source.
- **Recommendation:** Consider as supplement to Axiom for broader Apple doc coverage.

### 6.2 llm.codes

- **What:** Apple documentation transformed for AI readability, by Peter Steinberger
- **Website:** [llm.codes](https://steipete.me/posts/2025/llm-codes-transform-developer-docs)
- **Security:** Static documentation, no code execution
- **Recommendation:** Useful as a reference source for AI agents working on Apple platform code.

### 6.3 claude-code-ios-dev-guide (legacy reference)

- **What:** Community guide for using Claude Code specifically with Swift/SwiftUI projects
- **Repository:** [github.com/keskinonur/claude-code-ios-dev-guide](https://github.com/keskinonur/claude-code-ios-dev-guide)
- **Security:** Documentation only, no code execution
- **Recommendation:** It may be read as a general Swift/SwiftUI reference, but it does not define Super's active Codex setup.

---

## 7. Recommended Toolchain

Based on the research above, here is the recommended AI toolchain for Super development:

```
┌─────────────────────────────────────────────────────────┐
│                  AI Development Stack                    │
│                                                         │
│                 ┌──────────────────┐                    │
│                 │      Codex       │                    │
│                 │  (AI Agent Core) │                    │
│                 └────────┬─────────┘                    │
│                          │                              │
│              ┌───────────┼───────────┐                  │
│              ▼           ▼           ▼                  │
│       ┌────────────┐ ┌──────────┐ ┌──────────────────┐  │
│       │ AGENTS.md  │ │ .codex/  │ │ Apple-doc sources│  │
│       │ (canonical │ │ MCP/hooks│ │ (review before   │  │
│       │   rules)   │ │  /rules  │ │  adding an MCP)  │  │
│       └────────────┘ └──────────┘ └──────────────────┘  │
│                                                         │
│  ╳ Context7 — NOT RECOMMENDED (security concerns)       │
└─────────────────────────────────────────────────────────┘
```

### Installation Checklist

- [ ] Verify the checked-in MCP declarations with `codex mcp list --json`
- [ ] Keep `.codex/hooks.json` and `.codex/rules/default.rules` enabled; do not recreate Claude settings or hooks
- [ ] Keep `AGENTS.md` canonical and every `CLAUDE.md` as an untouched compatibility symlink
- [ ] Evaluate apple-docs-mcp or Axiom MCP only after auditing dependencies and network behavior
- [ ] Never run GSD's legacy installer in the Super project root

---

## 8. Security Rules for AI Tools

Regardless of which tools we adopt, these rules apply to all AI-assisted development on Super:

1. **Never use `--dangerously-skip-permissions`** on the development machine
2. **Never grant blanket filesystem access** — use Codex's sandbox and approval system
3. **Audit all MCP server dependencies** before installation (check `package.json`, verify no unexpected network calls)
4. **No external data sources treated as trusted** — always review AI-generated code, especially when informed by external documentation
5. **Secrets never in working directory** — use `.env` files excluded from git, Keychain for local secrets, CI secrets for pipelines
6. **AI agents run in isolation** — execution phases in Docker/VM/worktree, not on the host machine with full access
7. **All AI tool installations documented** — track versions, audit dates, and known vulnerabilities in this document
