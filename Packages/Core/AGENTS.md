# Core — Agent Guidelines

Shared primitives consumed by every applet. No applet may import another applet — they all funnel through Core.

## What lives here

- LLM layer: `LLMProvider` protocol, `LLMMessage`, `LLMStreamEvent`, `LLMProviderRegistry`.
- HTTP + SSE: `HTTPClient`, `URLSessionHTTPClient`, `SSEParser`.
- Tool system: `LLMTool`, `ToolRegistration`, `ToolExecution`, `ToolExecutor`, `ToolRegistry`, `RemoteHTTPToolExecutor`.
- Ambient utilities: `Clock`, `IDGenerator`, `KeychainClient`, `SuperAppInfo`, `FontRegistration`.
- Theme + brand primitives: `SuperTheme`, `SuperTypography`, `OKLCH`, `SuperFontScale`, `SuperMotion`, and the brand surfaces every applet reuses (`SplashView`, `SplashSpark`). SwiftUI imports and concrete `View` types are in-scope here when the surface is brand-neutral (i.e., not tied to any applet's domain) — the splash, theme tokens, and shared motion curves all qualify. Applet-specific UI does **not** belong here.
  - **`SuperTypography` is the single owner of font-face resolution** — the typographic companion to `SuperTheme`. Views read `@Environment(\.superTypography)` and call its semantic accessors (`display(_:)`, `font(_:)`, `mono(_:)`) instead of hand-writing `.font(.custom(...))` or `.font(.system(...))`. Swapping the brand face app-wide is one edit to a `make(_:)` arm. It carries the active `superFontScale`, so call sites never multiply the scale themselves. See `superpowers/specs/2026-05-29-supertypography-design.md`.

## Core-specific rules

Root [`../../AGENTS.md`](../../AGENTS.md) carries the shared rules. Core-specific additions:

- **No GRDB dependency.** Persistence (records, repositories, migrations) is each applet's concern; Core stays platform/persistence-neutral.
- **No applet-specific code.** Anything tied to a single applet's domain (Chat orchestration, Bible verse lookup, Todo task model) belongs in that applet's package, not here.

## Tests

Tests live in `Tests/CoreTests/` mirroring the source layout.
