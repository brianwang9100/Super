# Core — Agent Guidelines

Shared primitives consumed by every applet. No applet may import another applet — they all funnel through Core.

## What lives here

- LLM layer: `LLMProvider` protocol, `LLMMessage`, `LLMStreamEvent`, `LLMProviderRegistry`.
- HTTP + SSE: `HTTPClient`, `URLSessionHTTPClient`, `SSEParser`.
- Tool system: `LLMTool`, `ToolRegistration`, `ToolExecution`, `ToolExecutor`, `ToolRegistry`, `RemoteHTTPToolExecutor`.
- Ambient utilities: `Clock`, `IDGenerator`, `KeychainClient`, `SuperAppInfo`, `FontRegistration`.
- Theme + brand primitives: `SuperTheme`, `OKLCH`, `SuperFontScale`, `SuperMotion`, and the brand surfaces every applet reuses (`SplashView`, `SplashSpark`). SwiftUI imports and concrete `View` types are in-scope here when the surface is brand-neutral (i.e., not tied to any applet's domain) — the splash, theme tokens, and shared motion curves all qualify. Applet-specific UI does **not** belong here.

## Rules

- **No GRDB dependency.** Persistence (records, repositories, migrations) is each applet's concern; Core stays platform/persistence-neutral.
- **No applet-specific code.** Anything tied to a single applet's domain (Chat orchestration, Bible verse lookup, Todo task model) belongs in that applet's package, not here.
- **Sendable everywhere.** Types crossing concurrency boundaries conform to `Sendable`.
- **Structs for data, actors for identity.** Per the root AGENTS.md.
- **Swift 6 strict concurrency** is on; `swiftLanguageMode(.v6)` per target.
- **Inject side effects.** Clocks, ID generators, network, Keychain, etc. are all behind protocols so tests can substitute fakes.
- **Coverage target ≥80%** per root AGENTS.md.

## Tests

`swift test` from `Packages/Core/` must be green before any PR opens. Tests live in `Tests/CoreTests/` mirroring the source layout.
