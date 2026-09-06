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
- **UI** (`UI/`): SwiftUI views — `ChatScreen`, `ChatComposer`, `MessageList` (+ row views under `UI/Messages/`), `SidebarDrawer`, `Settings*Pane`, theme types. **Before naming a new SwiftUI view, read [`docs/NAMING_CONVENTIONS.md` Part 4](../../docs/NAMING_CONVENTIONS.md#part-4--swiftui-view-layer-chat-applet).** The markdown renderer (`MarkdownText`, `markdownTheme`, linkifier, autocloser, code blocks) lives in **Core** (`Core/UI/Markdown/`), shared with Bible; Chat projects its font-scale slider onto it via `ChatAppearance.markdownMetrics` inside the `.chatAppearance(_:)` modifier — keep that projection equal to Core's default at 1.0× (pinned by `ChatAppearanceTests`).
- **View models** (`ViewModels/`): `@Observable @MainActor final class` view models for every screen.

## Chat-specific rules

Root [`../../AGENTS.md`](../../AGENTS.md) carries the shared rules. Chat-specific additions:

- **Streaming-text persistence**: write the final `MessageRecord` only on `.messageComplete` (per ADR-BB-003 in `docs/Chat/ARCHITECTURE.md`). Do not persist intermediate buffer state.
- **LLM tests must mock `LLMProvider`.** Never hit a real LLM endpoint (OpenAI, local MLX, Ollama, anything).

## Tests

Snapshot fixtures live in `Tests/ChatTests/UI/__Snapshots__/`. SSE/LLM fixtures in `Tests/ChatTests/Fixtures/`.

Module-specific test patterns (root [`AGENTS.md`](../../AGENTS.md) §Testing.7 carries the shared rules):

- **`FakeLLMProvider` is the reference strict mock** — it `fatalError`s on an unscripted or empty-queue `stream(...)`. New LLM-path doubles match that contract; never hit a real endpoint.
- **Orchestration drain seams** — `ChatScreenViewModel._waitForPendingStreamTask()` / `_waitForPendingTitleTask()` (wait for the stream task first, then the title task it spawns) and `VoiceInputController._observeProcessedEvents()` are the canonical fire-and-forget drains. Await them; never yield-poll the observable state.

## Manual testing in the simulator

When you need to exercise the Chat streaming UI in the simulator — scroll behavior on send/keyboard, code-block render, thinking pill, error banner, anything that depends on a real streaming response — drive it through **`DebugLLMProvider`** (`Sources/Chat/LLM/DebugLLMProvider.swift`), not a real model. Do **not** wire an OpenAI/Gemini/Ollama key into the simulator just to test UI changes — that's slow, costs tokens, and adds a network-flake variable to bugs you're trying to reproduce.

- The provider is gated under `#if DEBUG` end-to-end (`LLMProviderKind.debug`, the provider class, both host bootstraps' register/seed call sites — `SuperOSAppBootstrap` and `SuperBibleAppBootstrap` both call into the shared `AppBootstrapSupport.seedDebugModelIfNeeded` + `hydrateProviders` plumbing — and the `SettingsViewModel` switch arm). It compiles out of Release entirely.
- `AppBootstrapSupport.seedDebugModelIfNeeded` inserts a `kind = .debug` model and marks it selected only if no other row is selected. Production Apple seeding runs first: an empty repository selects local on iOS 26 and PCC on iOS 27+, regardless of readiness. Explicitly choose Debug in the picker for simulator interaction tests; never let debug seeding mask the production default. The two app targets have separate sandboxed containers and independent configurations.
- The response bank (short ack, headings + bullets, code block with `swift` fence, long-form streaming-stress, optional thinking trace) is picked randomly per turn. Delays are randomized 15–80ms between chunks, with a 150–500ms pre-stream pause so the "Waiting" spark is visible.
- When you add a new response shape you want to test against (a wider markdown table, an unterminated code fence, a long emoji run), extend the `responseBank` array in `DebugLLMProvider.swift` rather than reaching for a real model.
