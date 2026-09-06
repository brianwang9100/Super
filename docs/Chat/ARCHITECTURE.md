# Chat: Architecture

> Internal architecture of the Chat applet -- the AI chatbot and cross-applet orchestrator in Super.
>
> **Prerequisite reading:** [MOBILE_ARCHITECTURE.md](../MOBILE_ARCHITECTURE.md) for the tool system, event bus, and data architecture protocols. [CLIENT_SERVER.md](../CLIENT_SERVER.md) for server communication and SSE streaming. [CHAT_INTERACTIONS.md](../CHAT_INTERACTIONS.md) for the full interaction catalog (66 user stories, 6 response types).

> **Status (2026-05-10):** The Chat MVP (M0–M12) is shipped — `Packages/Chat/` ships persistence (`ConversationRepository` / `MessageRepository` / `ToolCallRepository` / `CompactionCheckpointRepository` / `ModelConfigurationRepository` / `SettingRepository`), streaming (`OpenAICompatibleLLMProvider`, `SSEParser`), orchestration (`ChatSession` actor, `ChatSessionStore`, `ContextAssembler`, `Compactor`, `TitleGenerator`), one built-in tool (`TimeNowTool`), and the full SwiftUI surface (`ChatScreen`, `ChatComposer`, `MessageList`, `SidebarDrawer`, `SettingsSheet`, MarkdownUI + Splash rendering, on-device voice input via `SFSpeechRecognizer`). What is **not yet built**: cross-applet event-bus subscriptions (no other applets exist), shared chat-card renderer registry, server-mediated LLM proxy (the client today talks directly to the user's BYOK endpoint), and any sync-engine integration. See [`archived/IMPLEMENTATION_STATUS.md`](../archived/IMPLEMENTATION_STATUS.md) for the milestone-by-milestone build log.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Directory Structure](#2-directory-structure)
3. [Data Models (GRDB Records)](#3-data-models-grdb-records)
4. [Database Schema & Migrations](#4-database-schema--migrations)
5. [ChatSession & ChatSessionStore](#5-chatsession--chatsessionstore)
6. [ToolRouter](#6-toolrouter)
7. [System Prompts](#7-system-prompts)
8. [ChatViewModel](#8-chatviewmodel)
9. [Conversation Persistence & Sync](#9-conversation-persistence--sync)
10. [Event Bus Integration](#10-event-bus-integration)
11. [LLM Service & Server Communication](#11-llm-service--server-communication)
12. [Error Handling](#12-error-handling)
13. [Testing Strategy](#13-testing-strategy)
14. [ChatsApplet & ChatBriefing](#14-chatsapplet--chatbriefing)
15. [Decision Log](#15-decision-log)

---

## 1. Overview

Chat is a standalone Swift Package following the standard applet layout (Domain / Data / Service / UI). It depends only on `Core` -- never on another applet.

Chat has three responsibilities:

1. **AI Chat Interface.** Users send natural-language messages. Chat forwards them to the LLM via the server (`POST /api/ai/chat/stream`), streams the response back token-by-token, and renders it in the chat UI.

2. **Cross-Applet Orchestration.** Chat discovers tools registered by every installed applet through the `ToolRegistry` (defined in Core). When the LLM's response includes a tool call, Chat routes it to the correct applet's `ToolExecutor`, feeds the result back to the LLM, and continues until the LLM signals `endTurn`. The user experiences multi-applet actions as a single conversation turn.

3. **Conversation Persistence.** Conversations, messages, and tool call records are stored in Chat's own GRDB database (`chat.sqlite`). GRDBQuery provides reactive SwiftUI binding; the sync engine replicates history across devices.

Chat is always present and cannot be uninstalled. It registers no tools of its own -- it routes to other applets' tools.

---

## 2. Directory Structure

```
Chat/
├── Package.swift                       # Depends only on Core
├── Sources/
│   ├── Applet/
│   │   └── ChatsApplet.swift       # MiniApplet conformance (Section 14)
│   ├── Orchestration/
│   │   └── ChatBriefing.swift      # DefaultSystemPrompt.md loader
│   │
│   ├── Domain/
│   │   ├── Models/
│   │   │   ├── Conversation.swift      # Domain entity (not the GRDB record)
│   │   │   ├── Message.swift           # Domain entity with role enum
│   │   │   ├── ToolCallInfo.swift      # Domain representation of a tool call
│   │   │   └── ChatEvent.swift         # Stream event enum (Section 5)
│   │   ├── UseCases/
│   │   │   ├── SendMessageUseCase.swift        # Validates + saves user message
│   │   │   ├── StreamResponseUseCase.swift     # Manages the LLM stream lifecycle
│   │   │   ├── ExecuteToolCallUseCase.swift    # Validates + executes a single tool call
│   │   │   └── ManageConversationsUseCase.swift # Create, rename, soft-delete, list
│   │   └── Repositories/
│   │       ├── ConversationRepository.swift     # Protocol
│   │       └── MessageRepository.swift          # Protocol (includes tool call queries)
│   │
│   ├── Data/
│   │   ├── Database/
│   │   │   ├── ChatDatabase.swift           # DatabaseQueue setup + migration registration
│   │   │   ├── ConversationRecord.swift         # GRDB record struct
│   │   │   ├── MessageRecord.swift              # GRDB record struct
│   │   │   └── ToolCallRecord.swift             # GRDB record struct
│   │   ├── Repositories/
│   │   │   ├── GRDBConversationRepository.swift # ConversationRepository conformance
│   │   │   └── GRDBMessageRepository.swift      # MessageRepository conformance
│   │   └── Mappers/
│   │       └── RecordMappers.swift              # Domain <-> GRDB record conversion
│   │
│   ├── Service/
│   │   ├── Orchestration/
│   │   │   ├── ChatSession.swift                # Per-conversation turn loop (actor, Section 5)
│   │   │   ├── ChatSessionStore.swift           # Multiplexer of live sessions (actor, Section 5)
│   │   │   ├── ContextAssembler.swift           # Projects records → [LLMMessage] (struct, Section 5)
│   │   │   ├── Compactor.swift                  # Summarization checkpoint writer (actor, Section 5)
│   │   │   ├── TitleGenerator.swift             # First-turn title via LLM (struct, Section 5)
│   │   │   └── ToolRouter.swift                 # Routes tool calls to applet executors (actor, Section 6)
│   │   ├── LLM/
│   │   │   ├── LLMService.swift                 # Wraps Core's LLMProvider for Chat's needs
│   │   │   └── StreamParser.swift               # LLMStreamEvent -> ChatEvent translation
│   │   ├── Tools/
│   │   │   └── ChatTools.swift              # Empty -- Chat registers no tools
│   │   └── EventHandlers/
│   │       └── AppletChangeHandler.swift        # Subscribes to applet registry changes
│   │
│   └── UI/
│       ├── Screens/
│       │   ├── ChatView.swift                   # Main chat screen
│       │   ├── ConversationListView.swift        # Conversation sidebar / list
│       │   └── ChatSettingsView.swift        # Chat-specific settings
│       ├── Components/
│       │   ├── MessageBubble.swift               # User and AI message rendering
│       │   ├── ActionCard.swift                  # Tool call result card (pending/success/failed)
│       │   ├── SuggestionCard.swift              # Confirm/reject/edit card for destructive actions
│       │   ├── StreamingTextView.swift           # Incremental markdown + token fade-in
│       │   ├── InputBar.swift                    # Text field + send + mic
│       │   └── VoiceInputButton.swift            # Mic toggle with pulse animation
│       └── ViewModels/
│           ├── ChatViewModel.swift              # @Observable @MainActor (Section 8)
│           └── ConversationListViewModel.swift  # Conversation list state
│
└── Tests/
    ├── DomainTests/                             # Use case tests with mock repos
    ├── DataTests/                               # In-memory GRDB + snapshot tests
    └── ServiceTests/                            # Mock LLM + mock ToolRouter
```

---

## 3. Data Models (GRDB Records)

All records conform to `Codable`, `FetchableRecord`, `PersistableRecord`, and `Sendable`.

### ConversationRecord

```swift
struct ConversationRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "conversation"

    var id: String              // UUID string
    var title: String?          // Auto-generated from first user message, editable
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?        // Soft delete for sync
}
```

### MessageRecord

```swift
struct MessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "message"

    var id: String              // UUID string
    var conversationId: String  // FK -> conversation.id
    var role: MessageRole       // user | assistant | system | tool
    var content: String         // Text content; JSON-encoded for tool results
    var toolCallId: String?     // Non-nil when role == .tool; links to toolCall.id
    var createdAt: Date
    var tokenCount: Int?        // Input or output tokens consumed by this message
}

enum MessageRole: String, Codable, Sendable, CaseIterable {
    case user
    case assistant
    case system
    case tool
}
```

`MessageRole` is owned by Chat — not a re-export of Core's `LLMRole` — so the on-disk schema is decoupled from `LLMRole`'s evolution. The case set is identical to `LLMRole`'s today, but the separate type is a deliberate boundary: a future provider case in `LLMRole`, or a future Chat-only row kind (e.g. a compaction summary), becomes an explicit decision in the translation extension below rather than silent drift in the schema.

A small extension translates between the two enums when the record crosses the LLM boundary:

```swift
extension MessageRole {
    func asLLMRole() -> LLMRole {
        switch self {
        case .user: return .user
        case .assistant: return .assistant
        case .system: return .system
        case .tool: return .tool
        }
    }

    init(_ llmRole: LLMRole) {
        switch llmRole {
        case .user: self = .user
        case .assistant: self = .assistant
        case .system: self = .system
        case .tool: self = .tool
        }
    }
}
```

The translation is identity today; if the two enums ever diverge in case set, the compiler forces an explicit decision at the translation site.

The toolUseID/isError shape that distinguishes a tool-result *block* (vs. the row's *role*) lives on Core's `LLMContent.toolResult`. `MessageRecord.toolCallId` carries the row-level linkage to `ToolCallRecord`.

### ToolCallRecord

```swift
struct ToolCallRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "toolCall"

    var id: String              // Matches the LLM's tool_use id
    var messageId: String       // FK -> message.id (the assistant message that triggered this)
    var conversationId: String  // Denormalized for efficient per-conversation queries
    var toolName: String        // Namespaced: "todo.create", "calendar.list", etc.
    var parameters: String      // JSON-encoded [String: Any]
    var result: String?         // JSON-encoded ToolResult; nil while pending
    var status: ToolCallStatus
    var createdAt: Date
    var completedAt: Date?      // Non-nil once status is terminal
}

enum ToolCallStatus: String, Codable, Sendable {
    case pending                // LLM requested the call; not yet started
    case executing              // ToolExecutor is running
    case success                // Completed successfully
    case failed                 // Executor threw or returned isError
    case cancelled              // User or system cancelled
    case awaitingConfirmation   // Destructive action waiting for user approval
}
```

---

## 4. Database Schema & Migrations

Chat owns `chat.sqlite`. Migrations are registered in `ChatDatabase.swift` and applied at applet activation.

```swift
func registerChatMigrations(_ migrator: inout DatabaseMigrator) {

    migrator.registerMigration("v1_createTables") { db in

        // -- conversations --
        try db.create(table: "conversation") { t in
            t.primaryKey("id", .text)
            t.column("title", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("deletedAt", .datetime)
        }

        try db.create(
            index: "conversation_on_updatedAt",
            on: "conversation",
            columns: ["updatedAt"]
        )

        // -- messages --
        try db.create(table: "message") { t in
            t.primaryKey("id", .text)
            t.column("conversationId", .text).notNull()
                .references("conversation", onDelete: .cascade)
            t.column("role", .text).notNull()
            t.column("content", .text).notNull()
            t.column("toolCallId", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("tokenCount", .integer)
        }

        try db.create(
            index: "message_on_conversationId_createdAt",
            on: "message",
            columns: ["conversationId", "createdAt"]
        )

        // -- tool calls --
        try db.create(table: "toolCall") { t in
            t.primaryKey("id", .text)
            t.column("messageId", .text).notNull()
                .references("message", onDelete: .cascade)
            t.column("conversationId", .text).notNull()
            t.column("toolName", .text).notNull()
            t.column("parameters", .text).notNull()
            t.column("result", .text)
            t.column("status", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("completedAt", .datetime)
        }

        try db.create(
            index: "toolCall_on_conversationId",
            on: "toolCall",
            columns: ["conversationId"]
        )

        try db.create(
            index: "toolCall_on_messageId",
            on: "toolCall",
            columns: ["messageId"]
        )

        try db.create(
            index: "toolCall_on_status",
            on: "toolCall",
            columns: ["status"]
        )
    }
}
```

**Foreign key cascade behavior:**

- Deleting a `conversation` cascades to its `message` rows.
- Deleting a `message` cascades to its `toolCall` rows.
- Soft delete (`deletedAt`) is the normal path; hard deletes happen only after sync confirmation.

**Indexes rationale:**

| Index | Query it serves |
|-------|----------------|
| `conversation_on_updatedAt` | Conversation list sorted by recency |
| `message_on_conversationId_createdAt` | Loading message history for a conversation in chronological order |
| `toolCall_on_conversationId` | Fetching all tool calls for a conversation (analytics, retry) |
| `toolCall_on_messageId` | Joining tool calls to the assistant message that triggered them |
| `toolCall_on_status` | Querying pending/failed tool calls across all conversations |

---

## 5. ChatSession & ChatSessionStore

The shipped orchestration layer splits what earlier drafts of this section called the *Chat orchestrator* into two actors:

- **`ChatSession`** (`Packages/Chat/Sources/Chat/Orchestration/ChatSession.swift`) — one actor per conversation, owns the turn loop. Public entry points: `send(text:model:temperature:)`, `compact(model:)`, `cancel()`, `waitUntilFinished()`, `setAutoCompactPolicy(enabled:threshold:)`. Both `send` and `compact` return an `AsyncStream<ChatEvent>` (see [§5 ChatEvent](#chatevent)).
- **`ChatSessionStore`** (`Packages/Chat/Sources/Chat/Orchestration/ChatSessionStore.swift`) — app-level actor holding `[conversationId: ChatSession]`. `session(for:)` is get-or-create; `shutdown()` drains in-flight work on app exit; `runningConversations()` powers the sidebar's per-row spinner.

Supporting orchestration types (all in the same folder):

| Type | Kind | Role |
| --- | --- | --- |
| `ContextAssembler` / `ContextAssembly` | `struct` | Projects persisted `MessageRecord`s + `ToolCallRecord`s + the live `CompactionCheckpointRecord` into the `[LLMMessage]` shipped to the provider. Folds the checkpoint in as a leading system message; preserves true-leading `.system` rows. |
| `Compactor` | `actor` | Runs a summarization turn through the active provider and writes a new `CompactionCheckpointRecord` (atomic with prior demotion). Stateless beyond injected deps; shared across all sessions. |
| `TitleGenerator` | `struct` | Single-shot LLM call generating a 3–6-word title for a new conversation from its first user/assistant exchange. Consumed by `ChatScreenViewModel`, not by `ChatSession`. |
| `TokenEstimator` / `HeuristicTokenEstimator` | `protocol` + `struct` | chars/4 heuristic for prompt-budget accounting in MVP. |
| `SlashCommand` | `enum` | Composer-side dispatch. Today: `.compact`. Parsed at `ChatSession.send(text:)` entry — slash commands never persist a user `MessageRecord`. |
| `ChatSessionDriver` / `LiveChatSessionDriver` / `LazyConversationDriver` | `protocol` + adapters | Seam between the view model and the session. Multiple production conformers (one wraps a session directly, one ensures lazy save before the first turn). |

### Turn loop (canonical order)

1. Parse `SlashCommand`. If matched, dispatch (e.g. `/compact` → `compact(model:)`); no user `MessageRecord` is written.
2. Cancel the prior in-flight `Task` **and await its wind-down** (cancellation fence). Guarantees two turns never interleave GRDB writes for the same conversation.
3. Save the user `MessageRecord`; yield `.userMessageSaved(record)`.
4. Loop:
   1. Check cancellation.
   2. `maybeAutoCompact(model:)` — if over `autoCompactThreshold` and the compactor reports there is work to do, fire `.compactionStarted` / `.compactionCompleted` around a compaction pass.
   3. `assembleHistory(model:)` via `ContextAssembler`.
   4. Fetch enabled tools from `ToolRegistry`.
   5. Stream one turn from the active provider. Buffer text + thinking deltas in memory; yield as `.textDelta` / `.thinkingDelta`. On `.messageComplete` persist the assistant `MessageRecord` (only then, per [ADR-BB-003](#adr-bb-003-streaming-text-saved-only-on-completion)) and a `ToolCallRecord(status: .pending)` per requested tool call. **Empty turn** (no text, no tool calls) is not persisted and no `.assistantMessageSaved` fires.
   6. If no tool calls → finish.
   7. Otherwise execute each tool via `ToolRegistry`, write a tool-result `MessageRecord(role: .tool)`, update the `ToolCallRecord` status, and loop back.

Per-event contract (final, success, error cases), plus full sequence diagrams for the simple turn, tool-loop turn, auto-compaction, manual `/compact`, and title generation, live in [`ORCHESTRATION.md`](./ORCHESTRATION.md).

```swift
public actor ChatSession {
    public let conversationId: String

    public init(
        conversationId: String,
        messageRepository: any MessageRepository,
        toolCallRepository: any ToolCallRepository,
        checkpointRepository: any CompactionCheckpointRepository,
        llmProviderRegistry: LLMProviderRegistry,
        toolRegistry: ToolRegistry,
        contextAssembler: ContextAssembler = ContextAssembler(),
        compactor: Compactor,
        clock: any Clock = SystemClock(),
        idGenerator: any IDGenerator = UUIDGenerator(),
        autoCompactEnabled: Bool = true,
        autoCompactThreshold: Double = 0.75
    )

    public func send(text: String, model: LLMModel, temperature: Double = 1.0) async -> AsyncStream<ChatEvent>
    public func compact(model: LLMModel) async -> AsyncStream<ChatEvent>
    public func cancel()
    public func waitUntilFinished() async
    public func setAutoCompactPolicy(enabled: Bool, threshold: Double)

    public var isStreaming: Bool { get }
}

public actor ChatSessionStore {
    public func session(for conversationId: String) -> ChatSession
    public func cancel(for conversationId: String, wait: Bool = false) async
    public func shutdown() async
    public func runningConversations() async -> [String]
}
```

<a id="chatevent"></a>

### ChatEvent

```swift
public enum ChatEvent: Sendable, Equatable {
    case userMessageSaved(MessageRecord)
    case textDelta(String)
    case thinkingDelta(String)
    case toolCallStarted(ToolCallRecord)
    case toolCallCompleted(ToolCallRecord, ToolResult)
    case toolCallFailed(ToolCallRecord, String)
    case assistantMessageSaved(MessageRecord)
    case compactionStarted
    case compactionCompleted(CompactionCheckpointRecord)
    case error(LLMError)
}
```

**Stream contract.** A `send(...)` / `compact(...)` `AsyncStream<ChatEvent>` always finishes — it never throws. Failures arrive as a terminal `.error(...)` immediately before the stream closes, so consumers always get a clean signal that the turn is done and can persist whatever did make it through. UI rule: a `.compactionStarted` is always followed by **either** `.compactionCompleted` **or** a terminal `.error` — clear any "Compacting…" affordance on either.

For per-turn event ordering (simple turn, tool-loop turn, auto-compaction, manual `/compact`, title generation) plus full Mermaid sequence diagrams, see [`ORCHESTRATION.md`](./ORCHESTRATION.md).

---

## 6. ToolRouter

`ToolRouter` is an **actor** that maps tool name prefixes to applet `ToolExecutor` instances. It validates parameters before execution and handles executor lookup failures.

```swift
actor ToolRouter {
    private var executors: [String: any ToolExecutor] = [:]  // appletId -> executor
    private var toolIndex: [String: String] = [:]            // toolName -> appletId
    private var tools: [String: LLMTool] = [:]                // toolId -> LLMTool definition

    /// Register all tools and executor for an applet.
    func register(appletId: String, tools: [LLMTool], executor: any ToolExecutor) {
        executors[appletId] = executor
        for tool in tools {
            toolIndex[tool.id] = appletId
            self.tools[tool.id] = tool
        }
    }

    /// Remove an applet's tools and executor (applet was uninstalled).
    func unregister(appletId: String) {
        executors.removeValue(forKey: appletId)
        toolIndex = toolIndex.filter { $0.value != appletId }
        tools = tools.filter { toolIndex[$0.key] != nil }
    }

    /// Execute a tool call by name.
    func execute(
        toolName: String,
        parameters: [String: any Sendable]
    ) async throws -> ToolResult {
        guard let appletId = toolIndex[toolName] else {
            throw SuperError.toolNotFound(toolID: toolName)
        }
        guard let executor = executors[appletId] else {
            throw SuperError.toolNotFound(toolID: toolName)
        }

        // Validate required parameters against tool definition
        if let tool = tools[toolName] {
            try validateParameters(parameters, against: tool)
        }

        return try await executor.execute(input: parameters)
    }

    /// Whether a tool requires user confirmation before execution.
    func requiresConfirmation(toolName: String) -> Bool {
        guard let tool = tools[toolName] else { return true } // unknown tools always confirm
        return tool.category == .mutation || tool.category == .system
    }

    func allTools() -> [LLMTool] {
        Array(tools.values)
    }

    func registeredAppletIDs() -> [String] {
        Array(executors.keys)
    }

    private func validateParameters(
        _ params: [String: any Sendable],
        against tool: LLMTool
    ) throws {
        for param in tool.parameters where param.isRequired {
            guard params[param.name] != nil else {
                throw SuperError.invalidToolParameters(
                    toolID: tool.id,
                    details: "Missing required parameter: \(param.name)"
                )
            }
        }
    }
}
```

When the applet registry changes (an applet is installed or removed), `AppletChangeHandler` receives the `.system(.appletRegistryChanged)` event from the event bus and calls `register(...)` or `unregister(...)` on the `ToolRouter`.

---

## 7. System Prompts

`ChatSettings.systemPrompt` (edited from Settings → Prompt) is injected as the **leading `.system` `LLMMessage`** on every turn by `ContextAssembler.assemble(...)`. The value is trimmed; whitespace-only prompts skip injection so the LLM falls back to its built-in default behavior.

**Default value.** `ChatSettings.default.systemPrompt` is loaded once at type-init from `Packages/Chat/Sources/Chat/Resources/DefaultSystemPrompt.md` (bundled via `Bundle.module`). Editing the file edits the factory default; existing users keep whatever they've saved in Settings → Prompt because `ChatSettingsStore.load()` only consults the default when no row exists for the `systemPrompt` key.

**Wiring.** `ChatSession` holds a `currentSystemPrompt` cache mirroring the `autoCompact*` push pattern:

- **At app launch**, `SuperOSAppBootstrap` loads `ChatSettings` from `ChatSettingsStore` and passes `settings.systemPrompt` into `ChatSessionStore` — new sessions are constructed with it.
- **On Settings edits**, `SettingsViewModel.setSystemPrompt(_:)` writes to `ChatSettingsStore` and fans the new value out to every active session via `ChatSessionStore.setSystemPrompt(_:)`. Long-running sessions pick up the change on their next turn — no app restart, no per-session resubscribe.
- **Per turn**, `ChatSession.assemble(model:)` passes `currentSystemPrompt` to `ContextAssembler.assemble(...)`. The injection is a runtime decision, not a snapshot baked into the conversation, so changing the setting affects every chat immediately (matching ChatGPT custom-instruction and Claude.ai preferences semantics).

**Assembly order.** With every input present, the prompt array hands `ChatSession` this shape:

```
[0]                settings systemPrompt           (this section)
[1..k]             original .system rows from history (rare; preserved across compaction)
[k+1]              compaction checkpoint summary    (§ Compaction)
[k+2..]            post-checkpoint conversation
```

Most conversations don't have historical `.system` rows, so the practical order is `[settings prompt, checkpoint?, ...rest]`.

**Caching.** Prefix-based LLM caches (Anthropic, OpenAI) invalidate only on the turn the prompt content actually changes. Stable system prompts across turns cache normally; settings edits are rare in practice, so the cache cost is one miss per edit. Snapshotting at conversation creation would split identical prompts across conversations into different cache keys and is intentionally not the chosen design.

**Out of scope.** Cross-applet system-prompt content (active applets, recent activity) was the original ambition for `SystemPromptBuilder`. Today the LLM gets the tool list via the provider's structured `tools` parameter; richer cross-applet context will land alongside the event bus.

Other `.system` rows the LLM may see, independent of `ChatSettings.systemPrompt`:

1. **Compaction checkpoints.** `ContextAssembler` folds the live `CompactionCheckpointRecord` (when present) in right after the settings prompt.
2. **The title generator's internal prompt.** `TitleGenerator` sends its own static system prompt for the title-summarization round trip; this never affects the user's conversation.

---

## 8. ChatViewModel

The view model follows the project-wide pattern: `@Observable @MainActor final class`.

```swift
@Observable
@MainActor
final class ChatViewModel {
    // MARK: - Published State

    private(set) var messages: [MessageRecord] = []
    private(set) var streamingText: String = ""
    private(set) var isStreaming: Bool = false
    private(set) var activeToolCalls: [ToolCallRecord] = []

    // MARK: - Dependencies

    private let orchestrator: any ChatSessionDriver
    private let conversationRepository: any ConversationRepository
    private let eventBus: SuperEventBus

    private var streamTask: Task<Void, Never>?
    private var currentConversation: ConversationRecord?

    init(
        orchestrator: any ChatSessionDriver,
        conversationRepository: any ConversationRepository,
        eventBus: SuperEventBus
    ) {
        self.orchestrator = orchestrator
        self.conversationRepository = conversationRepository
        self.eventBus = eventBus
    }

    // MARK: - Actions

    /// Send a user message and stream the LLM response.
    func send(_ text: String) {
        guard let conversation = currentConversation else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isStreaming = true
        streamingText = ""
        activeToolCalls = []

        streamTask = Task {
            do {
                let stream = await orchestrator.sendMessage(text, in: conversation)
                for try await event in stream {
                    handleEvent(event)
                }
            } catch {
                // Error already yielded as .error event
            }
            isStreaming = false
            streamingText = ""
        }
    }

    /// Cancel the current LLM stream. Partial text is kept as-is.
    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    /// Approve a tool call that was awaiting confirmation.
    func approveToolCall(_ toolCall: ToolCallRecord) {
        Task {
            await orchestrator.resumeToolCall(toolCall, approved: true)
        }
    }

    /// Reject a tool call that was awaiting confirmation.
    func rejectToolCall(_ toolCall: ToolCallRecord) {
        Task {
            await orchestrator.resumeToolCall(toolCall, approved: false)
        }
        activeToolCalls.removeAll { $0.id == toolCall.id }
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: ChatEvent) {
        switch event {
        case .textDelta(let text):
            streamingText += text

        case .toolCallStarted(let toolCall):
            activeToolCalls.append(toolCall)

        case .toolCallAwaitingConfirmation(let toolCall):
            if let idx = activeToolCalls.firstIndex(where: { $0.id == toolCall.id }) {
                activeToolCalls[idx] = toolCall
            }

        case .toolCallCompleted(let toolCall, _):
            if let idx = activeToolCalls.firstIndex(where: { $0.id == toolCall.id }) {
                activeToolCalls[idx] = toolCall
            }

        case .toolCallFailed(let toolCall, _):
            if let idx = activeToolCalls.firstIndex(where: { $0.id == toolCall.id }) {
                activeToolCalls[idx] = toolCall
            }

        case .messageCompleted:
            // GRDBQuery handles reactive message list updates.
            // Reset streaming text since the full message is now in the DB.
            streamingText = ""

        case .error:
            isStreaming = false
        }
    }
}
```

**Key design decisions:**

- `messages` is populated via GRDBQuery (`@Query`) in the view layer for reactive updates -- the list refreshes automatically when the database changes. The view model does not manually manage this array; it is shown here for conceptual completeness.
- `streamingText` accumulates `.textDelta` events during streaming. It is reset to `""` when `.messageCompleted` fires, at which point the full message is in GRDB and GRDBQuery picks it up.
- `activeToolCalls` tracks in-flight tool calls so the UI can render action cards with the correct status (pending / executing / awaiting confirmation / success / failed).
- `streamTask` holds the current streaming task so `cancelStream()` can terminate it.

---

## 9. Conversation Persistence & Sync

### GRDB Storage

All conversations, messages, and tool call records live in `chat.sqlite`. Each record type follows the standard GRDB pattern (struct + Codable + FetchableRecord + PersistableRecord + Sendable).

### GRDBQuery for Reactive UI

The message list in `ChatView` uses `@Query` from [GRDBQuery](https://github.com/groue/GRDBQuery) — the project-wide bridge between GRDB and SwiftUI (see [MOBILE_ARCHITECTURE.md §8.2](../MOBILE_ARCHITECTURE.md#82-grdb-companion-packages)). The view subscribes to a `ValueObservation` on the `message` table filtered by `conversationId`, ordered by `createdAt`. When `ChatSession` saves a new message to GRDB, the view automatically re-renders -- no manual notification or observation plumbing needed.

```swift
struct ChatMessagesRequest: ValueObservationQueryable {
    static var defaultValue: [MessageRecord] { [] }

    let conversationId: String

    func fetch(_ db: Database) throws -> [MessageRecord] {
        try MessageRecord
            .filter(Column("conversationId") == conversationId)
            .order(Column("createdAt").asc)
            .fetchAll(db)
    }
}
```

### SyncableApplet Conformance

Chat conforms to `SyncableApplet`, which enables conversation history to replicate across devices via the standard sync mechanism (see [SYNC.md](../SYNC.md)). Soft-deleted records (`deletedAt != nil`) are retained locally until sync confirms the server has acknowledged the deletion, then hard-deleted.

### Token Tracking

`MessageRecord.tokenCount` records the number of tokens consumed by each message (input tokens for user messages when available, output tokens for assistant messages). This supports:

- **Token budget enforcement:** `ChatSession` can check cumulative token usage before sending a new request and warn the user when approaching limits.
- **Usage analytics:** Aggregate token consumption per conversation, per day, or per applet (via tool calls).

---

## 10. Event Bus Integration

Chat communicates with the rest of Super exclusively through the event bus. It never imports or depends on any other applet.

### Events Published

| Event | When |
|-------|------|
| `.aiStreamStarted(applet: .chat)` | User sends a message and the LLM stream opens |
| `.aiToolCallRequested(applet: .chat, tool:, input:)` | LLM requests a tool call |
| `.aiToolCallCompleted(applet: .chat, tool:, result:)` | Tool call finishes successfully |
| `.aiStreamCompleted(applet: .chat)` | LLM stream ends (endTurn) |

### Events Subscribed

| Event | Handler |
|-------|---------|
| `.appDidBecomeActive` | Refreshes conversation list |
| System-level applet registry changes | `AppletChangeHandler` rebuilds the `ToolRouter` tool index |

### What Chat Does NOT Subscribe To

Chat does **not** subscribe to individual applet data events (e.g., `dataCreated(applet: .todo, ...)`). It has no need to react to data changes in other applets unless it initiated the change via a tool call, in which case the result comes back through the `ToolResult` within the orchestration loop.

---

## 11. LLM Service & Server Communication

Chat never calls LLM providers directly. All LLM interactions go through the Super server:

- **Endpoint:** `POST /api/ai/chat/stream`
- **Request body:** Messages array + tool definitions + system prompt
- **Response:** SSE stream of `LLMStreamEvent` values (defined in Core's Networking package)
- **Server responsibilities:** API key management, rate limiting, token budgets, provider dispatch, tool definition validation

`LLMService` (in Chat's Service layer) wraps Core's `HTTPClient.stream()` method and produces an `AsyncThrowingStream<LLMStreamEvent, Error>`. `StreamParser` then converts these raw events into domain-level `ChatEvent` values that the orchestrator yields to the UI.

The full request/response flow, SSE parsing details, and error codes are documented in [CLIENT_SERVER.md](../CLIENT_SERVER.md) Section 6.

---

## 12. Error Handling

| Scenario | Behavior |
|----------|----------|
| **Network error during streaming** | Yield `.error` on the ChatEvent stream. UI shows an error card with a "Retry" button. Partial streamed text is preserved. |
| **Tool execution failure** | Save a `tool_result` message with the error content. The LLM receives the failure in its next turn and can explain it to the user or suggest alternatives. UI shows a failed action card. |
| **Token budget exceeded** | `ChatSession` checks cumulative token count before sending. If over budget, yield an `.error` event with a message suggesting the user start a new conversation. |
| **LLM provider error** | Server returns a provider-specific error in the SSE stream. `StreamParser` maps it to a `ChatEvent.error`. UI shows the error message with a "Retry" button. |
| **Tool not found** | `ToolRouter.execute()` throws `SuperError.toolNotFound`. Treated as a tool execution failure -- error sent back to the LLM as a `tool_result`. |
| **Invalid tool parameters** | `ToolRouter.validateParameters()` throws `SuperError.invalidToolParameters`. Same flow as tool not found. |
| **SSE stream interrupted** | `HTTPClient.stream()` throws on disconnection. The orchestrator yields `.error`. The user can retry, which starts a fresh request with the full conversation history. |

All tool execution errors are fed back to the LLM as `tool_result` messages with `isError: true`. This lets the LLM acknowledge failures conversationally rather than leaving the user staring at a silent chat.

---

## 13. Testing Strategy

### Domain Tests

Use cases tested with mock repositories. Pure logic, no database dependency.

```swift
@MainActor
final class SendMessageUseCaseTests: XCTestCase {

    func testSendMessageSavesUserMessage() async throws {
        let mockRepo = MockMessageRepository()
        let useCase = SendMessageUseCase(messageRepository: mockRepo)

        try await useCase.execute(text: "Hello", conversationId: "conv-1")

        XCTAssertEqual(mockRepo.savedMessages.count, 1)
        XCTAssertEqual(mockRepo.savedMessages[0].role, .user)
        XCTAssertEqual(mockRepo.savedMessages[0].content, "Hello")
        XCTAssertEqual(mockRepo.savedMessages[0].conversationId, "conv-1")
    }

    func testSendMessageRejectsEmptyText() async throws {
        let mockRepo = MockMessageRepository()
        let useCase = SendMessageUseCase(messageRepository: mockRepo)

        do {
            try await useCase.execute(text: "   ", conversationId: "conv-1")
            XCTFail("Expected error for empty text")
        } catch {
            XCTAssertTrue(mockRepo.savedMessages.isEmpty)
        }
    }
}
```

### Data Tests

GRDB repositories tested with in-memory `DatabaseQueue`. GRDBSnapshotTesting for schema assertions.

```swift
final class GRDBConversationRepositoryTests: XCTestCase {

    private func makeDatabase() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        registerChatMigrations(&migrator)
        try migrator.migrate(db)
        return db
    }

    func testFetchConversationsExcludesSoftDeleted() async throws {
        let db = try makeDatabase()
        let repo = GRDBConversationRepository(database: db)

        try await repo.save(ConversationRecord(
            id: "1", title: "Active", createdAt: .now, updatedAt: .now, deletedAt: nil
        ))
        try await repo.save(ConversationRecord(
            id: "2", title: "Deleted", createdAt: .now, updatedAt: .now, deletedAt: .now
        ))

        let results = try await repo.fetchAll()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "1")
    }

    func testDeleteConversationCascadesToMessages() async throws {
        let db = try makeDatabase()

        try db.write { db in
            try db.execute(sql: """
                INSERT INTO conversation (id, title, createdAt, updatedAt)
                VALUES ('c1', 'Test', datetime('now'), datetime('now'))
            """)
            try db.execute(sql: """
                INSERT INTO message (id, conversationId, role, content, createdAt)
                VALUES ('m1', 'c1', 'user', 'Hello', datetime('now'))
            """)
        }

        try db.write { db in
            try db.execute(sql: "DELETE FROM conversation WHERE id = 'c1'")
        }

        let messageCount = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE conversationId = 'c1'")
        }
        XCTAssertEqual(messageCount, 0)
    }

    func testMigrationCreatesExpectedSchema() throws {
        let db = try makeDatabase()

        let tables = try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='table' ORDER BY name
            """)
        }
        XCTAssertTrue(tables.contains("conversation"))
        XCTAssertTrue(tables.contains("message"))
        XCTAssertTrue(tables.contains("toolCall"))
    }
}
```

### Service Tests

`ChatSession` is tested with a strict-mock `LLMProvider` (`FakeLLMProvider` in `Packages/Chat/Tests/ChatTests/Orchestration/Helpers/FakeLLMProvider.swift`) plus in-memory repositories. The fake fails fast on misuse (empty script queue → `fatalError`) so a misconfigured test attributes the failure to its caller rather than tripping a later, unrelated test. See:

- `Packages/Chat/Tests/ChatTests/Orchestration/ChatSessionTests.swift` — turn loop happy path, cancellation, error mapping, empty-turn skipping.
- `Packages/Chat/Tests/ChatTests/Orchestration/ChatSessionToolLoopTests.swift` — multi-turn tool execution, success + failure feedback to the LLM.
- `Packages/Chat/Tests/ChatTests/Orchestration/ChatSessionStoreTests.swift` — per-conversation isolation, `cancel(for:wait:)`, `runningConversations()`, `shutdown()`.
- `Packages/Chat/Tests/ChatTests/Orchestration/ChatSessionCompactionTests.swift` — auto-compaction trigger and manual `/compact`.

Per [Chat's agent rules](../../Packages/Chat/AGENTS.md), tests must mock `LLMProvider`; **never** hit a real LLM endpoint (OpenAI, MLX, Ollama, etc.).

### Tool Routing Tests

```swift
final class ToolRouterTests: XCTestCase {

    func testRoutesToCorrectExecutorByPrefix() async throws {
        let router = ToolRouter()
        let todoExecutor = MockToolExecutor(toolID: "todo.create")
        let calendarExecutor = MockToolExecutor(toolID: "calendar.create")

        await router.register(
            appletId: "todo",
            tools: [LLMTool(id: "todo.create", name: "create", description: "Create task", category: .mutation, parameters: [], applet: .todo)],
            executor: todoExecutor
        )
        await router.register(
            appletId: "calendar",
            tools: [LLMTool(id: "calendar.create", name: "create", description: "Create event", category: .mutation, parameters: [], applet: .calendar)],
            executor: calendarExecutor
        )

        _ = try await router.execute(toolName: "todo.create", parameters: ["title": "Test"])
        XCTAssertTrue(todoExecutor.wasExecuted)
        XCTAssertFalse(calendarExecutor.wasExecuted)
    }

    func testUnknownToolThrowsNotFound() async {
        let router = ToolRouter()
        do {
            _ = try await router.execute(toolName: "nonexistent.tool", parameters: [:])
            XCTFail("Expected toolNotFound error")
        } catch {
            guard case SuperError.toolNotFound = error else {
                XCTFail("Expected toolNotFound, got \(error)")
                return
            }
        }
    }

    func testMissingRequiredParameterThrows() async throws {
        let router = ToolRouter()
        let executor = MockToolExecutor(toolID: "todo.create")
        let tool = LLMTool(
            id: "todo.create",
            name: "create",
            description: "Create task",
            category: .mutation,
            parameters: [LLMToolParameter(name: "title", type: .string, description: "Task title", isRequired: true, enumValues: nil)],
            applet: .todo
        )
        await router.register(appletId: "todo", tools: [tool], executor: executor)

        do {
            _ = try await router.execute(toolName: "todo.create", parameters: [:])
            XCTFail("Expected invalidToolParameters error")
        } catch {
            guard case SuperError.invalidToolParameters = error else {
                XCTFail("Expected invalidToolParameters, got \(error)")
                return
            }
        }
    }
}
```

### System Prompt Tests

Covered in `ContextAssemblerTests` and `ChatSessionTests`:

- `ContextAssemblerTests.systemPromptInjectedAtTopWhenNonEmpty` — non-empty prompt becomes the leading `.system` row.
- `ContextAssemblerTests.systemPromptIsTrimmedAndSkippedWhenWhitespaceOnly` — empty / whitespace prompts skip injection; interior whitespace preserved.
- `ContextAssemblerTests.systemPromptPrecedesCheckpointSummary` — settings prompt sits before the compaction summary.
- `ContextAssemblerTests.systemPromptPrecedesHistoricalSystemRowAndCheckpoint` — full ordering check when history also carries a leading `.system` row.
- `ContextAssemblerTests.systemPromptTokenCountIncludedInTotal` — the injected row is counted toward the budget.
- `ChatSessionTests.setSystemPromptPropagatesToNextProviderRequest` — runtime `setSystemPrompt(_:)` surfaces on the next provider request.

---

## 14. ChatsApplet & ChatBriefing

The Chat package exposes two pieces that the composition root reaches into:

**`ChatsApplet`** — a `MiniApplet` conformance (`appletID = "chats"`) for the *searchable history backdrop*, distinct from the floating chat overlay. Registered in `AppBootstrap.applets`. The chat overlay itself is **not** a registered applet — `AppShell` renders it directly on top of whichever backdrop is active, so there is no `chat` applet identity to conform.

```swift
public struct ChatsApplet: MiniApplet {
    public static let appletID: String = "chats"

    public init(chatDatabase: ChatDatabase) {
        self.chatDatabase = chatDatabase
    }

    public var displayName: String { "Chats" }
    public var accentColor: Color { /* muted sage green */ }
    public var systemPrompt: String { "" }   // no LLM block — the screen is a chrome view

    @MainActor
    public func iconView(size: CGFloat) -> AnyView { AnyView(ChatsIcon(size: size)) }

    @MainActor
    public func rootView() -> AnyView {
        AnyView(
            ChatsScreen()
                .databaseContext(.readOnly { chatDatabase.queue })
        )
    }

    private let chatDatabase: ChatDatabase
}
```

`ChatsScreen` reads `ConversationRecord` reactively through GRDBQuery `@Query(ActiveConversationsRequest())`, so writes from the overlay (new conversation, title generation, message bumping `updatedAt`) repaint without manual refresh. Tapping a row publishes `.openConversationRequested(id:)` on the `SuperEventBus`; `AppShell` drains and routes to its existing `selectConversation(id:)` flow. The green `+` button publishes `.newConversationRequested`.

**`ChatBriefing`** — a tiny helper that resolves `DefaultSystemPrompt.md` against Chat's SPM bundle:

```swift
public enum ChatBriefing {
    public static func load() -> String {
        AppletSystemPrompt.load(from: .module, resource: "DefaultSystemPrompt")
    }
}
```

`AppBootstrap` calls `ChatBriefing.load()` once at startup and hands the body to `ChatSessionStore` as the leading system message every conversation sees. Lives inside the Chat package (not `App/`) so `.module` resolves to Chat's bundle, where the markdown actually ships.

---

## 15. Decision Log

### ADR-BB-001: ChatSession is an Actor

**Status:** Accepted

**Context:** The orchestrator manages the conversation loop across multiple async operations: LLM streaming, tool execution, and GRDB writes. These operations interleave and mutate shared state (message history, pending tool calls).

**Decision:** `ChatSession` is an `actor`.

**Consequences:** Compiler-enforced data-race safety without manual locking. Actor reentrancy is acceptable here because each conversation loop is self-contained -- intermediate state mutations during `await` points are intentional (e.g., saving a message before executing a tool call). No `os_unfair_lock` needed.

---

### ADR-BB-002: Tool Calls Stored as Separate Records

**Status:** Accepted

**Context:** Tool calls could be embedded as JSON within the assistant message's `content` field, or stored as their own GRDB table.

**Decision:** `ToolCallRecord` is a standalone table with a `messageId` foreign key linking it to the assistant message that triggered it. `conversationId` is denormalized for efficient per-conversation queries.

**Consequences:**

- Tool calls are independently queryable (e.g., "show all failed tool calls," "count tool calls by applet").
- Per-tool analytics (execution time, success rate) are straightforward SQL.
- Individual tool calls can be retried without re-parsing message content.
- The tradeoff is an extra table and join, but Chat's query patterns (loading a conversation's messages with their tool calls) are well-served by the `messageId` index.

---

### ADR-BB-003: Streaming Text Saved Only on Completion

**Status:** Accepted

**Context:** During streaming, text deltas arrive rapidly (dozens per second). Writing each delta to GRDB would cause excessive I/O and trigger unnecessary GRDBQuery observation updates, resulting in view re-renders on every token.

**Decision:** `streamingText` is accumulated in `ChatViewModel`'s in-memory state. Only when the LLM signals message completion (`.messageComplete`) is the full text saved to GRDB as a single `MessageRecord`. GRDBQuery then fires one observation update.

**Consequences:**

- Streaming is smooth -- no GRDB write contention during token delivery.
- If the app crashes mid-stream, the partial response is lost. This is acceptable because the user can resend the message, and the LLM's response is non-deterministic anyway.
- The UI renders `streamingText` from the view model during streaming, then switches to the GRDB-backed `messages` array once the message is saved.

---

*Last updated: 2026-04-24*
