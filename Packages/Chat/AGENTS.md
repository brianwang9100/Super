# Chat — Agent Guidelines

The Chat applet: AI chatbot orchestration, persistence, UI. Pixel reference for every surface lives at `/Users/bwang/Development/Super/.design-tmp/chat/project/`.

## What lives here

- **Domain models** (`Models/`): `ConversationRecord`, `MessageRecord`, `ToolCallRecord`, `ModelConfigurationRecord`, `ToolEnablementRecord`, `SettingRecord`, `CompactionCheckpointRecord`. All `Codable, FetchableRecord, PersistableRecord, Sendable`.
- **Database** (`Database/`): `ChatDatabase` (wraps `DatabaseQueue` on `chat.sqlite`), `Migrations`.
- **Repositories** (`Repositories/`): one per record, protocol-typed.
- **LLM provider** (`LLM/`): `OpenAICompatibleLLMProvider` conforming to `Core.LLMProvider`.
- **Orchestration** (`Orchestration/`): `ChatSession` actor (one per conversation), `ChatSessionStore` actor (holds concurrent sessions), `ContextAssembler`, `Compactor`, `TokenEstimator`, `SystemPromptBuilder`, `SlashCommand`, `ChatEvent`.
- **Tools** (`Tools/`): `TimeNowTool` (built-in local).
- **Voice** (`Voice/`): `VoiceInputService` protocol + `SpeechRecognizerVoiceInputService` (on-device `SFSpeechRecognizer`).
- **UI** (`UI/`): SwiftUI views — `ChatScreen`, `ChatComposer`, `MessageListView`, `SidebarDrawer`, `Settings*Pane`, message-part renderers, theme types.
- **View models** (`ViewModels/`): `@Observable @MainActor final class` view models for every screen.

## Rules

- **Do not import other applets.** Cross-applet communication runs through Core (event bus when it lands; absent in MVP).
- **Persistence is GRDB only.** No SwiftData / Core Data.
- **GRDB naming**: `camelCase` Swift property names = `camelCase` columns. Foreign keys are `<referencedTableSingular>Id`. Primary key is `id` (String UUID). Indexes follow `<tableName>_on_<column>[_<column>]`. See root AGENTS.md §Persistence for the full convention.
- **Streaming-text persistence**: write the final `MessageRecord` only on `.messageComplete` (per ADR-BB-003 in `docs/Chat/ARCHITECTURE.md`). Do not persist intermediate buffer state.
- **LLM tests must mock `LLMProvider`.** Never hit a real LLM endpoint (OpenAI, local MLX, Ollama, anything).
- **Snapshot tests** land in the same PR as the view they cover. See root AGENTS.md §Testing.2 for the per-state matrix (light/dark/sepia × default/Dynamic Type XXL).
- **Coverage target ≥70%** per root AGENTS.md.

## Tests

`swift test` from `Packages/Chat/` must be green before any PR opens. Snapshot fixtures live in `Tests/ChatTests/UI/__Snapshots__/`. SSE/LLM fixtures in `Tests/ChatTests/Fixtures/`.
