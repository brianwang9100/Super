# Super Chat MVP — Implementation Status

**If you are an AI session or engineer resuming this work: read this file first.** It is the single source of truth for *where we are*. The plan is the source of truth for *what we are doing*.

## Quick links

- **Plan**: `/Users/bwang/.claude/plans/zany-dazzling-willow.md` — the full approved implementation plan (all 13 milestones M0–M12).
- **Project agent rules**: `/Users/bwang/Development/Super/AGENTS.md`. `CLAUDE.md` is a symlink to it.
- **Design reference (canonical visual)**: `/Users/bwang/Development/Super/.design-tmp/chat/project/`
  - `Super.html` — entry point.
  - `src/theme.jsx` — palette tokens (oklch) for Light / Dark / Sepia.
  - `src/chat-view.jsx` — chat screen, composer, header, pills.
  - `src/sidebar.jsx` — drawer.
  - `src/settings.jsx` — settings sheet + panes.
  - `src/message-parts.jsx` — block renderers (text / thinking / tool / code).
  - `src/data.jsx` — seed data (also useful as test fixtures).
  - `chats/chat1.md` — the user/designer chat log that established verbosity semantics, composer shape, etc.
- **Architecture docs** (under `docs/`): `PRODUCT_VISION.md`, `MOBILE_ARCHITECTURE.md`, `Chat/ARCHITECTURE.md`, `CLIENT_SERVER.md`, `SYNC.md`, `AUTH.md`, `CI_PIPELINE.md`, `SECURITY.md`, `OBSERVABILITY.md`, `AI_TOOLS.md`, `DEVELOPMENT_SETUP.md`.

## Current state

- **Active milestone**: M1 — Core primitives (next up)
- **Last action**: M0 done — repo at `/Users/bwang/Development/Super/` initialized, both SPM packages (Core, Chat) scaffolded with all M1+M2 deps wired (GRDB 7.10, GRDBQuery 0.11, swift-markdown-ui 2.4.1, Splash 0.16, swift-snapshot-testing 1.19.2, GRDBSnapshotTesting 0.4.2), `Super.xcodeproj` generated via `xcodegen` (linked against both local packages), `.mcp.json` + `.claude/settings.local.json` written for `xcodebuildmcp` + `ios-simulator-mcp`, `docs/DEVELOPMENT_SETUP.md` §8.5 documents MCP tooling. `swift test` green in both packages; `xcodebuild -scheme Super build` for iPhone 17 sim succeeded; app installed and launched in the simulator showing the placeholder wordmark + version line. The plan's SuperBig→Super rename was **skipped per user direction**.
- **Repo root**: `/Users/bwang/Development/Super/`
- **Next concrete sub-step (M1)**: scaffold `Packages/Core/Sources/Core/LLM/` with `LLMProvider`, `LLMMessage`, `LLMRole`, `LLMContent`, `LLMModel`, `ModelConfiguration`, `LLMStreamEvent` (include `.thinkingDelta`), `LLMProviderRegistry` (actor). Write the corresponding tests under `Tests/CoreTests/LLM/`.

## Session-resume procedure

1. Read the **Current state** block above.
2. Skim the **Milestone status** table below to see the whole picture.
3. Jump to the in-progress milestone's detail section further down for the latest specific notes (file paths touched, pending sub-steps).
4. Pull the corresponding milestone block out of the plan file for full requirements.
5. Resume.

Do not re-litigate scope. The plan is approved. If something in the plan looks wrong, flag it to the user before changing course — don't silently deviate.

## Milestone status

| # | Title | Status | Updated |
| --- | --- | --- | --- |
| M0 | Project scaffolding | `[x] done` | 2026-04-24 |
| M1 | Core primitives | `[ ] not_started` | — |
| M2 | Chat persistence | `[ ] not_started` | — |
| M3 | OpenAI-compatible streaming | `[ ] not_started` | — |
| M4 | Session orchestration | `[ ] not_started` | — |
| M5 | Compaction | `[ ] not_started` | — |
| M6 | Tool system + built-in tool | `[ ] not_started` | — |
| M7 | Chat UI | `[ ] not_started` | — |
| M8 | Sidebar drawer | `[ ] not_started` | — |
| M9 | Settings | `[ ] not_started` | — |
| M10 | Markdown + code + thinking rendering | `[ ] not_started` | — |
| M11 | Voice input | `[ ] not_started` | — |
| M12 | End-to-end polish + coverage | `[ ] not_started` | — |

Legend: `[ ]` not started · `[~]` in progress · `[!]` blocked · `[x]` done.

## Update discipline

- **Starting a milestone**: flip its checkbox to `[~]`, set `Status:` to `in_progress`, stamp `Last updated:` to today (absolute date), write a one-line `Notes:` about the first concrete sub-step.
- **Pausing mid-milestone**: update `Notes:` with the latest file touched and the exact next sub-step. Enough detail that a cold reader can resume in under 5 minutes.
- **Finishing a milestone**: flip to `[x]`, set `Status:` to `done`, summarize what landed + where the tests live, update the `Current state` block at the top to point at the next milestone.
- Commit this file in the same PR as the milestone work it describes — never as a standalone "status update" commit.

---

## M0 — Project scaffolding

- **Checkbox**: `[x]` done
- **Status**: `done`
- **Last updated**: 2026-04-24
- **Notes**:
  - Skipped the plan's SuperBig→Super rename per user direction; repo lives at `/Users/bwang/Development/Super/`.
  - `git init -b main` + `.gitignore` (excludes `.design-tmp/`, `.DS_Store`, SPM build artifacts, Xcode user state).
  - `Packages/Core/` (Swift 6, iOS 18+, no deps) — `Sources/Core/Core.swift` + 1 placeholder test, `AGENTS.md` + `CLAUDE.md` symlink.
  - `Packages/Chat/` (Swift 6, iOS 18+, deps: `GRDB.swift` 7.10.0, `GRDBQuery` 0.11.0, `swift-markdown-ui` 2.4.1, `Splash` 0.16.0; test deps: `swift-snapshot-testing` 1.19.2, `GRDBSnapshotTesting` 0.4.2; local `Core` dep) — `Sources/Chat/Chat.swift` + 2 placeholder tests, `AGENTS.md` + `CLAUDE.md` symlink.
  - `xcodegen` (2.45.4) installed via Homebrew; `project.yml` describes the iOS 18+ `Super` app target linked to both local packages; `xcodegen generate` produces `Super.xcodeproj`.
  - `App/{SuperApp.swift, ContentView.swift, Info.plist, Assets.xcassets/}` placeholders. ContentView prints the wordmark, "Chat MVP scaffolding", and `Core v… · Chat v…`.
  - `.mcp.json` wires `xcodebuildmcp` + `ios-simulator-mcp` (the latter replaces the plan's placeholder "Axiom MCP" — verified npm package). `.claude/settings.json` (project-shared, checked in — note: the plan said `.local.json` but the local-suffixed file is conventionally per-developer and globally git-ignored, so the shared settings live in `settings.json`) allowlists those MCP tools and a small set of safe Bash commands (`swift test`, `xcodebuild`, `xcrun simctl`, `git status/diff/log/add/commit`).
  - `docs/DEVELOPMENT_SETUP.md` §8.5 added to document the MCP tooling story (what each server does, smoke checks, fallback to plain bash).
  - Verifications: `swift test` green in both packages; `xcodebuild -scheme Super -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' build` succeeded; app installed and launched in the iPhone 17 simulator (PID confirmed); screenshot shows the placeholder wordmark.
  - Files added in this milestone (high level): `.gitignore`, `.mcp.json`, `.claude/settings.local.json`, `project.yml`, `Super.xcodeproj/`, `App/{SuperApp.swift, ContentView.swift, Info.plist, Assets.xcassets/*}`, `Packages/Core/{Package.swift, Sources/Core/Core.swift, Tests/CoreTests/CoreTests.swift, AGENTS.md, CLAUDE.md}`, `Packages/Chat/{Package.swift, Sources/Chat/Chat.swift, Tests/ChatTests/ChatTests.swift, AGENTS.md, CLAUDE.md}`, `docs/DEVELOPMENT_SETUP.md` (edited).

## M1 — Core primitives

- **Checkbox**: `[ ]` not_started
- **Status**: `not_started`
- **Last updated**: —
- **Notes**: awaiting M0. First sub-step on resume: scaffold `Packages/Core/Sources/Core/LLM/` with `LLMProvider`, `LLMMessage`, `LLMStreamEvent` (include `.thinkingDelta`), `LLMModel`.

## M2 — Chat persistence

- **Checkbox**: `[ ]` not_started
- **Status**: `not_started`
- **Last updated**: —
- **Notes**: all GRDB records (`ConversationRecord`, `MessageRecord`, `ToolCallRecord`, `ModelConfigurationRecord`, `ToolEnablementRecord`, `CompactionCheckpointRecord`, `SettingRecord`) + migrations + repositories. In-memory `DatabaseQueue` + `GRDBSnapshotTesting` for integration tests.

## M3 — OpenAI-compatible streaming

- **Checkbox**: `[ ]` not_started
- **Status**: `not_started`
- **Last updated**: —
- **Notes**: `OpenAICompatibleLLMProvider` handling plain OpenAI + reasoning (DeepSeek/R-series) + tool-call deltas. SSE fixtures checked into `Packages/Chat/Tests/Fixtures/`. Default test target for MVP development is the user's local MLX server at `http://127.0.0.1:1111/v1` with a Qwen model.

## M4 — Session orchestration

- **Checkbox**: `[ ]` not_started
- **Status**: `not_started`
- **Last updated**: —
- **Notes**: `ChatSession` actor per conversation, `ChatSessionStore` actor holding concurrent sessions. Switching conversations does not cancel streams. Persistence only on `.messageCompleted` (per ADR-BB-003 in `docs/Chat/ARCHITECTURE.md`).

## M5 — Compaction

- **Checkbox**: `[ ]` not_started
- **Status**: `not_started`
- **Last updated**: —
- **Notes**: `ContextAssembler`, `Compactor` actor, `TokenEstimator`, `/compact` slash command, `CompactionCheckpointRecord` wiring. Auto-compact threshold default 75%, user-configurable.

## M6 — Tool system + built-in tool

- **Checkbox**: `[ ]` not_started
- **Status**: `not_started`
- **Last updated**: —
- **Notes**: `TimeNowTool` (the only real tool shipped in MVP). `RemoteHTTPToolExecutor` implemented + tested but nothing registered remote for v1.

## M7 — Chat UI

- **Checkbox**: `[ ]` not_started
- **Status**: `not_started`
- **Last updated**: —
- **Notes**: Pixel parity with `.design-tmp/chat/project/src/chat-view.jsx`. Single composer button flipping mic↔send. Three-theme support (Light / Dark / Sepia) with user-adjustable accent hue. Fonts bundled: Geist, Instrument Serif, JetBrains Mono.

## M8 — Sidebar drawer

- **Checkbox**: `[ ]` not_started
- **Status**: `not_started`
- **Last updated**: —
- **Notes**: `SidebarDrawer` per `.design-tmp/chat/project/src/sidebar.jsx`. Applet rows for Todo/Recipes/Bible/Finance are visual placeholders (non-functional). Running chat spinner on leading edge of title.

## M9 — Settings

- **Checkbox**: `[ ]` not_started
- **Status**: `not_started`
- **Last updated**: —
- **Notes**: 9 panes total (Models, Theme, System Prompt, Default Verbosity, Appearance, Tools, Compaction, Data, About). Matches `.design-tmp/chat/project/src/settings.jsx` plus Tools and Compaction per user request.

## M10 — Markdown + code + thinking rendering

- **Checkbox**: `[ ]` not_started
- **Status**: `not_started`
- **Last updated**: —
- **Notes**: MarkdownUI + Splash. Block renderers match `.design-tmp/chat/project/src/message-parts.jsx`. Verbosity semantics: Simple collapses thinking+tool, Thinking expands thinking only, Verbose expands both. User toggles override.

## M11 — Voice input

- **Checkbox**: `[ ]` not_started
- **Status**: `not_started`
- **Last updated**: —
- **Notes**: `SFSpeechRecognizer` on-device only. Invoked by the composer's trailing button when the field is empty. `NSSpeechRecognitionUsageDescription` + `NSMicrophoneUsageDescription` added to Info.plist.

## M12 — End-to-end polish + coverage

- **Checkbox**: `[ ]` not_started
- **Status**: `not_started`
- **Last updated**: —
- **Notes**: Coverage thresholds per AGENTS.md (Core ≥80%, applets ≥70%). Doc updates: add `ToolDefinition`, `ChatSessionStore`, `ContextAssembler`, `Compactor`, `CompactionCheckpointRecord`, `.thinkingDelta`, `.compactionStarted`/`.compactionCompleted` to the architecture docs; update `CLIENT_SERVER.md` to describe the MVP "no-server" mode.

---

## Notes for future sessions

- **Never rename files listed in the plan's Critical Files list without updating both the plan and this file.** Agents relying on grepped paths break silently otherwise.
- **Never re-record snapshot tests to "make them pass"** — per AGENTS.md §Testing, only re-record when the visual change is intentional and explained in the PR.
- **Never skip hooks** (`--no-verify`) or bypass tests — per AGENTS.md.
- **Module-boundary rule**: Chat imports Core. App imports Chat + Core. Nothing else. No cross-applet imports (though there's only one applet in MVP).
- **Never commit without running `swift test` in each touched package locally** — per AGENTS.md §Testing.3.
