# Super: AI Development Tools

> Evaluation of AI-assisted development tools for building Super, with security assessments.

---

## 1. Purpose

This document evaluates AI development tools that could accelerate Super's development. Each tool is assessed for functionality, Swift/iOS relevance, security posture, and fit within our autonomous AI-agent workflow (see [CI_PIPELINE.md](./CI_PIPELINE.md)).

---

## 2. Tool Summary

| Tool | Type | What It Does | License | Cost | Security Rating |
|------|------|-------------|---------|------|-----------------|
| **Axiom** | Claude Code plugin + MCP server | Apple platform development skills, agents, and reference docs | MIT | Free | Good |
| **GSD (Get Shit Done)** | Workflow orchestration layer | Spec-driven planning/execution with fresh contexts per task | MIT | Free | Moderate (with caveats) |
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

Two integration modes:

1. **Claude Code Plugin (primary):** Install via `/plugin marketplace add CharlesWiltgen/Axiom`. Skills are automatically suggested based on conversational context (e.g., asking about "memory leaks" triggers `axiom-memory-debugging`).

2. **MCP Server (secondary):** TypeScript/Node.js MCP server using stdio transport. Works with VS Code, Cursor, Claude Desktop, Gemini CLI, and Xcode 26.3+ (Apple's native agentic coding support). Exposes skills as MCP Resources, Prompts, and Tools.

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
| **Permission model** | Runs within Claude Code's permission system (explicit approval for sensitive operations) |
| **Security policy** | None published — no formal "we don't send your data" declaration |
| **Source auditable** | Yes, fully open source MIT. MCP server source at `mcp-server/src/` |

**Verdict: Good.** Local-only, no network calls, open source, auditable. The only gap is the lack of a formal security policy, but the architecture itself is sound — it's fundamentally just curated reference material served locally.

**Recommendation: Adopt.** This is the most directly relevant tool for Super. Install as a Claude Code plugin for all Apple platform development work.

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

Installs ~50 markdown files, a Node.js CLI helper, and event hooks into your `.claude/` directory. Adds 29 slash commands and 12 custom agent definitions.

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
| **Data sent via underlying LLM** | GSD runs on Claude Code, which sends your code to Anthropic's API. This is inherent to any AI coding assistant, not GSD-specific. |
| **Filesystem access** | Reads your project directory, creates `.planning/` and `.claude/` files, makes git commits |
| **`--dangerously-skip-permissions` recommendation** | **This is the primary concern.** GSD recommends disabling Claude Code's permission system for automated execution. See details below. |
| **Source auditable** | Yes, fully open source MIT |
| **Security contact** | security@gsd.build |

**The `--dangerously-skip-permissions` Issue:**

GSD's documentation recommends running Claude Code with `--dangerously-skip-permissions` to avoid manually approving each file operation, git commit, or bash command. While GSD itself has safeguards (`allowed-tools` frontmatter, secret detection, sensitive file deny lists), the underlying concern is real:

- In January 2026, a developer lost ~11GB of files when Claude executed `rm -rf` with permissions skipped
- PromptArmor demonstrated that hidden text in documents could manipulate Claude into exfiltrating files via allowlisted APIs
- Security consensus: never run `--dangerously-skip-permissions` on your primary machine

**Mitigations we would apply:**

1. **Never use `--dangerously-skip-permissions` on the host machine.** Use default permission mode or granular `allowed-tools`.
2. Run GSD execution phases in **isolated environments** (Docker containers, VMs, or git worktrees)
3. Use GSD's planning phases (discuss/plan) interactively, then review specs before execution
4. Git checkpoints before each session allow `git reset` recovery

**Verdict: Moderate.** GSD itself is safe and well-designed. The risk comes from the operational recommendation to disable permissions. If we enforce our own permission policy (no `--dangerously-skip-permissions`), GSD is a valuable workflow tool.

**Recommendation: Adopt with guardrails.** Use for project planning and structured execution. Never disable permissions. Run execution in isolated environments. Complements our CI_PIPELINE.md agent workflow well.

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

### 6.3 claude-code-ios-dev-guide

- **What:** Community guide for using Claude Code specifically with Swift/SwiftUI projects
- **Repository:** [github.com/keskinonur/claude-code-ios-dev-guide](https://github.com/keskinonur/claude-code-ios-dev-guide)
- **Security:** Documentation only, no code execution
- **Recommendation:** Reference for best practices when our AI agents work on Super's Swift code.

---

## 7. Recommended Toolchain

Based on the research above, here is the recommended AI toolchain for Super development:

```
┌─────────────────────────────────────────────────────────┐
│                  AI Development Stack                    │
│                                                         │
│  ┌─────────────────┐   ┌─────────────────────────────┐ │
│  │     GSD          │   │         Axiom                │ │
│  │  (Orchestration) │   │  (Apple Platform Skills)     │ │
│  │                  │   │                              │ │
│  │  Plan → Execute  │   │  Swift 6, SwiftUI, GRDB,    │ │
│  │  Fresh contexts  │   │  Xcode debugging, perf,     │ │
│  │  Parallel waves  │   │  concurrency, accessibility │ │
│  └────────┬─────────┘   └──────────────┬──────────────┘ │
│           │                            │                 │
│           └────────────┬───────────────┘                 │
│                        ▼                                 │
│              ┌──────────────────┐                        │
│              │   Claude Code    │                        │
│              │  (AI Agent Core) │                        │
│              └────────┬─────────┘                        │
│                       │                                  │
│           ┌───────────┼───────────┐                      │
│           ▼           ▼           ▼                      │
│    ┌────────────┐ ┌────────┐ ┌──────────────────┐       │
│    │apple-docs  │ │llm.codes│ │claude-code-ios   │       │
│    │   -mcp     │ │        │ │  -dev-guide       │       │
│    │(Apple docs)│ │(Ref)   │ │(Best practices)   │       │
│    └────────────┘ └────────┘ └──────────────────┘       │
│                                                         │
│  ╳ Context7 — NOT RECOMMENDED (security concerns)       │
└─────────────────────────────────────────────────────────┘
```

### Installation Checklist

- [ ] Install Axiom: `/plugin marketplace add CharlesWiltgen/Axiom`
- [ ] Install GSD: `npx get-shit-done-cc@latest` (in Super project root)
- [ ] Configure GSD: never use `--dangerously-skip-permissions`; run execution phases in isolated environments
- [ ] Evaluate apple-docs-mcp for additional Apple documentation coverage
- [ ] Audit Axiom MCP server dependencies (`package.json`) before first use
- [ ] Audit GSD Node.js helper (`gsd-tools.cjs`) before first use

---

## 8. Security Rules for AI Tools

Regardless of which tools we adopt, these rules apply to all AI-assisted development on Super:

1. **Never use `--dangerously-skip-permissions`** on the development machine
2. **Never grant blanket filesystem access** — use Claude Code's granular permission system
3. **Audit all MCP server dependencies** before installation (check `package.json`, verify no unexpected network calls)
4. **No external data sources treated as trusted** — always review AI-generated code, especially when informed by external documentation
5. **Secrets never in working directory** — use `.env` files excluded from git, Keychain for local secrets, CI secrets for pipelines
6. **AI agents run in isolation** — execution phases in Docker/VM/worktree, not on the host machine with full access
7. **All AI tool installations documented** — track versions, audit dates, and known vulnerabilities in this document
