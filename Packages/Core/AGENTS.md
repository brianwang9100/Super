# Core — Agent Guidelines

Shared primitives consumed by every applet. No applet may import another applet — they all funnel through Core.

## What lives here

- LLM layer: `LLMProvider` protocol, `LLMMessage`, `LLMStreamEvent`, `LLMProviderRegistry`.
- HTTP + SSE: `HTTPClient`, `URLSessionHTTPClient`, `SSEParser`.
- Tool system: `LLMTool`, `ToolRegistration`, `ToolExecution`, `ToolExecutor`, `ToolRegistry`, `RemoteHTTPToolExecutor`.
- Ambient utilities: `Clock`, `IDGenerator`, `KeychainClient`, `SuperAppInfo`, `FontRegistration`.
- Theme + brand primitives: `SuperTheme`, `SuperTypography`, `OKLCH`, `SuperFontScale`, `SuperMotion`, and the brand surfaces every applet reuses (`SplashView`, `SplashSpark`). SwiftUI imports and concrete `View` types are in-scope here when the surface is brand-neutral (i.e., not tied to any applet's domain) — the splash, theme tokens, and shared motion curves all qualify. Applet-specific UI does **not** belong here.
  - **`SuperTypography` is the single owner of font-face resolution** — the typographic companion to `SuperTheme`. The *target* pattern: views read `@Environment(\.superTypography)` and call its semantic accessors (`display(_:)`, `font(_:)`, `mono(_:)`) instead of hand-writing `.font(.custom(...))` or `.font(.system(...))`; swapping the brand face app-wide is then one edit to a `make(_:)` arm, and call sites never multiply `superFontScale` themselves (the struct folds it in). **The linted targets (App, Core, Chat) are now fully migrated and lint-enforced** — the `super_typography_only` SwiftLint rule (root [`.swiftlint.yml`](../../.swiftlint.yml)) fails the build on any raw `.font(.system…)` / `.font(.custom…)` / `Font.system` / `Font.custom` there; this package is the one path-exempt caller (`SuperTypography.swift`). Migration of the not-yet-linted applet packages (Bible, Todo) is still rolling out across follow-up PRs, and those packages aren't in `.swiftlint.yml`'s `included` list yet — add a package to that list in the same PR that finishes migrating it. **New code everywhere should use `SuperTypography`.** See `superpowers/specs/2026-05-29-supertypography-design.md`.

## Core-specific rules

Root [`../../AGENTS.md`](../../AGENTS.md) carries the shared rules. Core-specific additions:

- **No GRDB dependency.** Persistence (records, repositories, migrations) is each applet's concern; Core stays platform/persistence-neutral.
- **No applet-specific code.** Anything tied to a single applet's domain (Chat orchestration, Bible verse lookup, Todo task model) belongs in that applet's package, not here.

## Tests

Tests live in `Tests/CoreTests/` mirroring the source layout.

Module-specific test patterns (root [`AGENTS.md`](../../AGENTS.md) §Testing.7 carries the shared rules):

- **Per-test HTTP isolation** — HTTP/SSE tests stub through `URLProtocolStub` keyed by a fresh per-test `stubID` (+ `defer` unregister), never a global stub, so the suite stays parallel without cross-test contamination.
- **Await the bus, don't poll it** — `SuperEventBus` tests synchronize by awaiting the stream iterator's `next()`; `events()` registers the subscriber synchronously before it returns, so a subscribe-then-assert needs no sleep.
