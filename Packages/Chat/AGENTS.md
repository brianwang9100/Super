# Chat — Agent Guidelines

The Chat applet: AI chatbot orchestration, persistence, UI. Pixel reference for every surface lives at `/Users/bwang/Development/Super/.design-tmp/chat/project/`.

## What lives here

- **Domain models** (`Models/`): `ConversationRecord`, `MessageRecord`, `ToolCallRecord`, `ModelConfigurationRecord`, `ToolEnablementRecord`, `SettingRecord`, `CompactionCheckpointRecord`. All `Codable, FetchableRecord, PersistableRecord, Sendable`.
- **Database** (`Database/`): `ChatDatabase` (wraps `DatabaseQueue` on `chat.sqlite`), `Migrations`.
- **Repositories** (`Repositories/`): one per record, protocol-typed.
- **LLM provider** (`LLM/`): `OpenAICompatibleLLMProvider` conforming to `Core.LLMProvider`; `DebugLLMProvider` (DEBUG builds only — see "Manual testing in the simulator" below).
- **Orchestration** (`Orchestration/`): `ChatSession` actor (one per conversation), `ChatSessionStore` actor (holds concurrent sessions), `ContextAssembler`, `Compactor`, `TokenEstimator`, `TitleGenerator`, `SlashCommand`, `ChatEvent`. `ChatSessionDriver` protocol (view-model seam) + `LiveChatSessionDriver` adapter live alongside the consuming view model.
- **Tools** (`Tools/`): `TimeNowTool` (built-in local).
- **Voice** (`Voice/`): `VoiceInputService` protocol + `SpeechRecognizerVoiceInputService` (on-device `SFSpeechRecognizer`).
- **UI** (`UI/`): SwiftUI views — `ChatScreen`, `ChatComposer`, `MessageList` (+ row views under `UI/Messages/`), `SidebarDrawer`, `Settings*Pane`, theme types. **Before naming a new SwiftUI view, read [`docs/NAMING_CONVENTIONS.md` Part 4](../../docs/NAMING_CONVENTIONS.md#part-4--swiftui-view-layer-chat-applet).**
- **View models** (`ViewModels/`): `@Observable @MainActor final class` view models for every screen.

## Rules

- **Do not import other applets.** Cross-applet communication runs through Core (event bus when it lands; absent in MVP).
- **Persistence is GRDB only.** No SwiftData / Core Data.
- **GRDB naming**: `camelCase` Swift property names = `camelCase` columns. Foreign keys are `<referencedTableSingular>Id`. Primary key is `id` (String UUID). Indexes follow `<tableName>_on_<column>[_<column>]`. See [`docs/NAMING_CONVENTIONS.md` Part 5 — Persistence schema](../../docs/NAMING_CONVENTIONS.md#part-5--persistence-schema) for the full convention.
- **Streaming-text persistence**: write the final `MessageRecord` only on `.messageComplete` (per ADR-BB-003 in `docs/Chat/ARCHITECTURE.md`). Do not persist intermediate buffer state.
- **LLM tests must mock `LLMProvider`.** Never hit a real LLM endpoint (OpenAI, local MLX, Ollama, anything).
- **Snapshot tests** land in the same PR as the view they cover. See root AGENTS.md §Testing.2 for the per-state matrix (light/dark/sepia × default/Dynamic Type XXL).
- **Coverage target ≥70%** per root AGENTS.md.

## Tests

`swift test` from `Packages/Chat/` must be green before any PR opens. Snapshot fixtures live in `Tests/ChatTests/UI/__Snapshots__/`. SSE/LLM fixtures in `Tests/ChatTests/Fixtures/`.

## Manual testing in the simulator

When you need to exercise the Chat streaming UI in the simulator — scroll behavior on send/keyboard, code-block render, thinking pill, error banner, anything that depends on a real streaming response — drive it through **`DebugLLMProvider`** (`Sources/Chat/LLM/DebugLLMProvider.swift`), not a real model. Do **not** wire an OpenAI/Gemini/Ollama key into the simulator just to test UI changes — that's slow, costs tokens, and adds a network-flake variable to bugs you're trying to reproduce.

- The provider is gated under `#if DEBUG` end-to-end (`LLMProviderKind.debug`, the provider class, both host bootstraps' register/seed call sites — `SuperOSAppBootstrap` and `SuperBibleAppBootstrap` both call into the shared `AppBootstrapHelpers.seedDebugModelIfNeeded` + `hydrateProviders` plumbing — and the `SettingsViewModel` switch arm). It compiles out of Release entirely.
- `AppBootstrapHelpers.seedDebugModelIfNeeded` inserts a single `kind = .debug` `ModelConfigurationRecord` on first launch and marks it selected iff no other row is selected. So a fresh `xcrun simctl install` lands on the debug model by default; if you already have a real model wired, the debug entry just shows up as an alternative in the model picker. The two app targets have separate sandboxed containers, so each gets its own debug seed independently.
- The response bank (short ack, headings + bullets, code block with `swift` fence, long-form streaming-stress, optional thinking trace) is picked randomly per turn. Delays are randomized 15–80ms between chunks, with a 150–500ms pre-stream pause so the "Waiting" spark is visible.
- When you add a new response shape you want to test against (a wider markdown table, an unterminated code fence, a long emoji run), extend the `responseBank` array in `DebugLLMProvider.swift` rather than reaching for a real model.
