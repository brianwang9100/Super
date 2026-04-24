# Core — Agent Guidelines

Shared primitives consumed by every applet. No applet may import another applet — they all funnel through Core.

## What lives here

- LLM layer: `LLMProvider` protocol, `LLMMessage`, `LLMStreamEvent`, `LLMProviderRegistry`.
- HTTP + SSE: `HTTPClient`, `URLSessionHTTPClient`, `SSEParser`.
- Tool system: `AITool`, `ToolDefinition`, `ToolExecution`, `ToolExecutor`, `ToolRegistry`, `RemoteHTTPToolExecutor`.
- Ambient utilities: `Clock`, `IDGenerator`, `KeychainClient`, `SuperAppInfo`.
- Cross-applet shared types: `ChatVerbosity`.

## Rules

- **No GRDB dependency.** Core is data + protocols only. Persistence is each applet's concern.
- **Sendable everywhere.** Types crossing concurrency boundaries conform to `Sendable`.
- **Structs for data, actors for identity.** Per the root AGENTS.md.
- **Swift 6 strict concurrency** is on; `swiftLanguageMode(.v6)` per target.
- **Inject side effects.** Clocks, ID generators, network, Keychain, etc. are all behind protocols so tests can substitute fakes.
- **Coverage target ≥80%** per root AGENTS.md.

## Tests

`swift test` from `Packages/Core/` must be green before any PR opens. Tests live in `Tests/CoreTests/` mirroring the source layout.
