# Core — Agent Guidelines

Shared primitives consumed by every applet. No applet may import another applet — they all funnel through Core.

## What lives here

- LLM layer: `LLMProvider` protocol, `LLMMessage`, `LLMStreamEvent`, `LLMProviderRegistry`.
- HTTP + SSE: `HTTPClient`, `URLSessionHTTPClient`, `SSEParser`.
- Tool system: `LLMTool`, `ToolRegistration`, `ToolExecution`, `ToolExecutor`, `ToolRegistry`, `RemoteHTTPToolExecutor`.
- Ambient utilities: `Clock`, `IDGenerator`, `KeychainClient`, `SuperAppInfo`, `FontRegistration`.
- Theme + brand primitives: `SuperTheme`, `SuperTypography`, `OKLCH`, `SuperFontScale`, `SuperMotion`, and the brand surfaces every applet reuses (`SplashView`, `SplashSpark`). SwiftUI imports and concrete `View` types are in-scope here when the surface is brand-neutral (i.e., not tied to any applet's domain) — the splash, theme tokens, and shared motion curves all qualify. Applet-specific UI does **not** belong here.
  - **`SuperTypography` is the single owner of font-face resolution** — the typographic companion to `SuperTheme`. The *target* pattern: views read `@Environment(\.superTypography)` and call its semantic accessors (`display(_:)`, `font(_:)`, `mono(_:)`) instead of hand-writing `.font(.custom(...))` or `.font(.system(...))`; swapping the brand face app-wide is then one edit to a `make(_:)` arm, and call sites never multiply `superFontScale` themselves (the struct folds it in). **Migration is rolling out across follow-up PRs** — shell injection + Chat (PR B), Todo (PR C), Bible + the Bible-fontScale fix (PR D) — so direct `.font(.custom(...))`/`.font(.system(...))` call sites still exist in the meantime. **New code should use `SuperTypography`; do not enforce the rule against not-yet-migrated views until their PR lands.** See `superpowers/specs/2026-05-29-supertypography-design.md`.

## Core-specific rules

Root [`../../AGENTS.md`](../../AGENTS.md) carries the shared rules. Core-specific additions:

- **No GRDB dependency.** Persistence (records, repositories, migrations) is each applet's concern; Core stays platform/persistence-neutral.
- **No applet-specific code.** Anything tied to a single applet's domain (Chat orchestration, Bible verse lookup, Todo task model) belongs in that applet's package, not here.

## Tests

Tests live in `Tests/CoreTests/` mirroring the source layout.
