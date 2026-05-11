# Chat: Architecture

> Internal architecture of the Chat applet -- the AI chatbot and cross-applet orchestrator in Super.
>
> **Prerequisite reading:** [MOBILE_ARCHITECTURE.md](../MOBILE_ARCHITECTURE.md) for the tool system, event bus, and data architecture protocols. [CLIENT_SERVER.md](../CLIENT_SERVER.md) for server communication and SSE streaming. [CHAT_INTERACTIONS.md](../CHAT_INTERACTIONS.md) for the full interaction catalog (66 user stories, 6 response types).

> **Status (2026-05-10):** The Chat MVP (M0–M12) is shipped — `Packages/Chat/` ships persistence (`ConversationRepository` / `MessageRepository` / `ToolCallRepository` / `CompactionCheckpointRepository` / `ModelConfigurationRepository` / `SettingRepository`), streaming (`OpenAICompatibleLLMProvider`, `SSEParser`), orchestration (`ChatSession` actor, `ChatSessionStore`, `ContextAssembler`, `Compactor`, `TitleGenerator`), one built-in tool (`TimeNowTool`), and the full SwiftUI surface (`ChatScreen`, `ChatComposer`, `MessageListView`, `SidebarDrawer`, `SettingsSheet`, MarkdownUI + Splash rendering, on-device voice input via `SFSpeechRecognizer`). What is **not yet built**: cross-applet event-bus subscriptions (no other applets exist), shared chat-card renderer registry, server-mediated LLM proxy (the client today talks directly to the user's BYOK endpoint), and any sync-engine integration. See [`archived/IMPLEMENTATION_STATUS.md`](../archived/IMPLEMENTATION_STATUS.md) for the milestone-by-milestone build log.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Directory Structure](#2-directory-structure)
3. [Data Models (GRDB Records)](#3-data-models-grdb-records)
4. [Database Schema & Migrations](#4-database-schema--migrations)
5. [ChatOrchestrator](#5-chatorchestrator)
6. [ToolRouter](#6-toolrouter)
7. [SystemPromptBuilder](#7-systempromptbuilder)
8. [ChatViewModel](#8-chatviewmodel)
9. [Conversation Persistence & Sync](#9-conversation-persistence--sync)
10. [Event Bus Integration](#10-event-bus-integration)
11. [LLM Service & Server Communication](#11-llm-service--server-communication)
12. [Error Handling](#12-error-handling)
13. [Testing Strategy](#13-testing-strategy)
14. [ChatApplet Conformance](#14-chatapplet-conformance)
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
│   ├── ChatApplet.swift            # SuperApplet conformance (Section 14)
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
│   │   │   ├── ManageConversationsUseCase.swift # Create, rename, soft-delete, list
│   │   │   └── BuildSystemPromptUseCase.swift  # Delegates to SystemPromptBuilder
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
│   │   │   ├── ChatOrchestrator.swift           # The core loop (actor, Section 5)
│   │   │   ├── ToolRouter.swift                 # Routes tool calls to applet executors (actor, Section 6)
│   │   │   └── SystemPromptBuilder.swift        # Builds system prompt (struct, Section 7)
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

## 5. ChatOrchestrator

`ChatOrchestrator` is an **actor** that owns the core conversation loop. It is the single entry point for sending a message and receiving the streamed response.

```swift
actor ChatOrchestrator {
    private let llmService: LLMService
    private let toolRouter: ToolRouter
    private let messageRepository: any MessageRepository
    private let conversationRepository: any ConversationRepository
    private let systemPromptBuilder: SystemPromptBuilder

    init(
        llmService: LLMService,
        toolRouter: ToolRouter,
        messageRepository: any MessageRepository,
        conversationRepository: any ConversationRepository,
        systemPromptBuilder: SystemPromptBuilder
    ) {
        self.llmService = llmService
        self.toolRouter = toolRouter
        self.messageRepository = messageRepository
        self.conversationRepository = conversationRepository
        self.systemPromptBuilder = systemPromptBuilder
    }

    /// Sends a user message and returns a stream of ChatEvents.
    /// The stream stays open until the LLM signals endTurn with no pending tool calls.
    func sendMessage(
        _ text: String,
        in conversation: ConversationRecord
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // 1. Save user message
                    let userMessage = MessageRecord(
                        id: UUID().uuidString,
                        conversationId: conversation.id,
                        role: .user,
                        content: text,
                        toolCallId: nil,
                        createdAt: Date.now,
                        tokenCount: nil
                    )
                    try await messageRepository.save(userMessage)

                    // 2. Build message history
                    let history = try await messageRepository.fetchAll(
                        conversationId: conversation.id
                    )

                    // 3. Build system prompt
                    let activeApplets = await toolRouter.registeredAppletIDs()
                    let tools = await toolRouter.allTools()
                    let systemPrompt = systemPromptBuilder.build(
                        activeApplets: activeApplets,
                        tools: tools,
                        timezone: .current,
                        recentActivitySummary: nil
                    )

                    // 4. Enter the orchestration loop
                    try await orchestrationLoop(
                        systemPrompt: systemPrompt,
                        history: history,
                        conversation: conversation,
                        continuation: continuation
                    )

                    continuation.finish()
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// The loop: send to LLM -> stream response -> handle tool calls -> repeat.
    private func orchestrationLoop(
        systemPrompt: String,
        history: [MessageRecord],
        conversation: ConversationRecord,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws {
        var currentHistory = history

        while true {
            // Send to LLM via server SSE
            let stream = llmService.stream(
                systemPrompt: systemPrompt,
                messages: currentHistory
            )

            var accumulatedText = ""
            var pendingToolCalls: [ToolCallRecord] = []

            for try await event in stream {
                switch event {
                case .textDelta(let text):
                    accumulatedText += text
                    continuation.yield(.textDelta(text))

                case .toolUse(let id, let name, let parameters):
                    let toolCall = ToolCallRecord(
                        id: id,
                        messageId: "", // set after assistant message saved
                        conversationId: conversation.id,
                        toolName: name,
                        parameters: encodeJSON(parameters),
                        result: nil,
                        status: .pending,
                        createdAt: Date.now,
                        completedAt: nil
                    )
                    pendingToolCalls.append(toolCall)
                    continuation.yield(.toolCallStarted(toolCall))

                case .messageComplete(let usage):
                    // Save the assistant message with accumulated text
                    let assistantMessage = MessageRecord(
                        id: UUID().uuidString,
                        conversationId: conversation.id,
                        role: .assistant,
                        content: accumulatedText,
                        toolCallId: nil,
                        createdAt: Date.now,
                        tokenCount: usage.outputTokens
                    )
                    try await messageRepository.save(assistantMessage)
                    continuation.yield(.messageCompleted(assistantMessage))

                    // Link tool calls to this message and save them
                    for var toolCall in pendingToolCalls {
                        toolCall.messageId = assistantMessage.id
                        try await saveToolCall(toolCall)
                    }

                case .error(let llmError):
                    continuation.yield(.error(llmError))
                }
            }

            // If no tool calls, the LLM is done (endTurn)
            if pendingToolCalls.isEmpty {
                break
            }

            // Execute each tool call
            for var toolCall in pendingToolCalls {
                // Check if confirmation is required
                let requiresConfirmation = await toolRouter.requiresConfirmation(
                    toolName: toolCall.toolName
                )
                if requiresConfirmation {
                    toolCall.status = .awaitingConfirmation
                    try await updateToolCall(toolCall)
                    continuation.yield(.toolCallAwaitingConfirmation(toolCall))
                    // Await user approval (handled externally via approveToolCall/rejectToolCall)
                    // For now, the loop pauses here -- the ViewModel resumes it
                    continue
                }

                // Execute the tool
                toolCall.status = .executing
                try await updateToolCall(toolCall)

                do {
                    let result = try await toolRouter.execute(
                        toolName: toolCall.toolName,
                        parameters: decodeJSON(toolCall.parameters)
                    )
                    toolCall.status = .success
                    toolCall.result = encodeJSON(result)
                    toolCall.completedAt = Date.now
                    try await updateToolCall(toolCall)
                    continuation.yield(.toolCallCompleted(toolCall, result))

                    // Save tool result as a message for the LLM
                    let toolResultMessage = MessageRecord(
                        id: UUID().uuidString,
                        conversationId: conversation.id,
                        role: .tool,
                        content: result.content,
                        toolCallId: toolCall.id,
                        createdAt: Date.now,
                        tokenCount: nil
                    )
                    try await messageRepository.save(toolResultMessage)
                } catch {
                    toolCall.status = .failed
                    toolCall.result = "{\"error\": \"\(error.localizedDescription)\"}"
                    toolCall.completedAt = Date.now
                    try await updateToolCall(toolCall)
                    continuation.yield(.toolCallFailed(toolCall, error.localizedDescription))

                    // Send failure as tool result so the LLM can explain it
                    let errorMessage = MessageRecord(
                        id: UUID().uuidString,
                        conversationId: conversation.id,
                        role: .tool,
                        content: "Error: \(error.localizedDescription)",
                        toolCallId: toolCall.id,
                        createdAt: Date.now,
                        tokenCount: nil
                    )
                    try await messageRepository.save(errorMessage)
                }
            }

            // Refresh history and loop back to the LLM with tool results
            currentHistory = try await messageRepository.fetchAll(
                conversationId: conversation.id
            )

            // Reset for next iteration
            accumulatedText = ""
            pendingToolCalls = []
        }
    }
}
```

### ChatEvent

The stream emits `ChatEvent` values consumed by `ChatViewModel` to render the conversation in real time:

```swift
enum ChatEvent: Sendable {
    case textDelta(String)
    case toolCallStarted(ToolCallRecord)
    case toolCallAwaitingConfirmation(ToolCallRecord)
    case toolCallCompleted(ToolCallRecord, ToolResult)
    case toolCallFailed(ToolCallRecord, String)
    case messageCompleted(MessageRecord)
    case error(Error)
}
```

### Loop Lifecycle

The orchestration loop continues until the LLM returns `endTurn` (a response with text but no tool calls). Each iteration:

1. Stream text deltas to the UI.
2. Collect tool calls from the response.
3. Save the assistant message and tool call records to GRDB.
4. Execute each tool call (or pause for confirmation).
5. Save tool results as `toolResult` messages.
6. Send the updated history back to the LLM.
7. Stream the follow-up response.

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

## 7. SystemPromptBuilder

`SystemPromptBuilder` is a **struct** (pure function, no state) that assembles the system prompt sent to the LLM before each request.

```swift
struct SystemPromptBuilder: Sendable {
    func build(
        activeApplets: [String],
        tools: [LLMTool],
        timezone: TimeZone,
        recentActivitySummary: String?
    ) -> String {
        var sections: [String] = []

        // 1. Role definition
        sections.append("""
        You are Chat, the AI assistant for Super. You help users manage \
        their tasks, calendar, home, finances, and more by calling tools provided \
        by the installed applets. Be concise. Bias toward action when the user's \
        intent is clear.
        """)

        // 2. Available applets
        sections.append("Active applets: \(activeApplets.joined(separator: ", "))")

        // 3. Available tools (structured tool definitions are also sent via the API,
        //    but a natural-language summary helps the LLM reason about tool selection)
        let toolSummary = tools.map { "- \($0.id): \($0.description)" }
            .joined(separator: "\n")
        sections.append("Available tools:\n\(toolSummary)")

        // 4. Current context
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.timeZone = timezone
        sections.append("Current date/time: \(formatter.string(from: Date.now))")
        sections.append("Timezone: \(timezone.identifier)")

        // 5. Optional recent activity
        if let summary = recentActivitySummary {
            sections.append("Recent activity:\n\(summary)")
        }

        // 6. Behavioral instructions
        sections.append("""
        Response guidelines:
        - For clear, non-destructive requests: execute the tool and confirm inline.
        - For destructive, batch, or ambiguous requests: propose the action and \
          wait for user approval.
        - Always include a deep link when you perform an action in another applet.
        - If a tool call fails, explain the failure and suggest alternatives.
        - Do not invent tools that are not in the available list.
        """)

        return sections.joined(separator: "\n\n")
    }
}
```

The system prompt is rebuilt on every `sendMessage` call so it always reflects the current set of installed applets and registered tools.

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

    private let orchestrator: ChatOrchestrator
    private let conversationRepository: any ConversationRepository
    private let eventBus: SuperEventBus

    private var streamTask: Task<Void, Never>?
    private var currentConversation: ConversationRecord?

    init(
        orchestrator: ChatOrchestrator,
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

The message list in `ChatView` uses `@Query` from [GRDBQuery](https://github.com/groue/GRDBQuery) — the project-wide bridge between GRDB and SwiftUI (see [MOBILE_ARCHITECTURE.md §8.2](../MOBILE_ARCHITECTURE.md#82-grdb-companion-packages)). The view subscribes to a `ValueObservation` on the `message` table filtered by `conversationId`, ordered by `createdAt`. When `ChatOrchestrator` saves a new message to GRDB, the view automatically re-renders -- no manual notification or observation plumbing needed.

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

- **Token budget enforcement:** `ChatOrchestrator` can check cumulative token usage before sending a new request and warn the user when approaching limits.
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
| **Token budget exceeded** | `ChatOrchestrator` checks cumulative token count before sending. If over budget, yield an `.error` event with a message suggesting the user start a new conversation. |
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

`ChatOrchestrator` tested with mock `LLMService` and mock `ToolRouter` to verify the orchestration loop without network or real tool execution.

```swift
final class ChatOrchestratorTests: XCTestCase {

    func testOrchestrationLoopExecutesToolAndContinues() async throws {
        let mockLLM = MockLLMService()
        // First response: text + tool call
        // Second response (after tool result): text + endTurn (no tool calls)
        mockLLM.responses = [
            [.textDelta("Let me check. "), .toolUse(id: "tc-1", name: "todo.list", parameters: [:]), .messageComplete(usage: .init(inputTokens: 10, outputTokens: 20))],
            [.textDelta("You have 3 tasks."), .messageComplete(usage: .init(inputTokens: 30, outputTokens: 15))]
        ]

        let mockRouter = MockToolRouter()
        mockRouter.results["todo.list"] = ToolResult(
            toolID: "todo.list",
            content: "[{\"title\": \"Buy milk\"}, {\"title\": \"Call dentist\"}, {\"title\": \"Fix bug\"}]",
            isError: false,
            artifacts: []
        )

        let mockMessageRepo = MockMessageRepository()
        let mockConversationRepo = MockConversationRepository()

        let orchestrator = ChatOrchestrator(
            llmService: mockLLM,
            toolRouter: mockRouter,
            messageRepository: mockMessageRepo,
            conversationRepository: mockConversationRepo,
            systemPromptBuilder: SystemPromptBuilder()
        )

        let conversation = ConversationRecord(
            id: "conv-1", title: "Test", createdAt: .now, updatedAt: .now, deletedAt: nil
        )

        var events: [ChatEvent] = []
        let stream = await orchestrator.sendMessage("Show my tasks", in: conversation)
        for try await event in stream {
            events.append(event)
        }

        // Verify the loop: text -> tool started -> tool completed -> text -> message completed
        XCTAssertTrue(events.contains { if case .textDelta("Let me check. ") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .toolCallStarted = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .toolCallCompleted = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .textDelta("You have 3 tasks.") = $0 { return true }; return false })

        // Verify tool was executed
        XCTAssertTrue(mockRouter.executedTools.contains("todo.list"))

        // Verify messages were saved (user + assistant + tool_result + assistant)
        XCTAssertEqual(mockMessageRepo.savedMessages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(mockMessageRepo.savedMessages.filter { $0.role == .assistant }.count, 2)
        XCTAssertEqual(mockMessageRepo.savedMessages.filter { $0.role == .tool }.count, 1)
    }

    func testToolFailureIsFedBackToLLM() async throws {
        let mockLLM = MockLLMService()
        mockLLM.responses = [
            [.textDelta("Creating task. "), .toolUse(id: "tc-1", name: "todo.create", parameters: ["title": "Test"]), .messageComplete(usage: .init(inputTokens: 10, outputTokens: 15))],
            [.textDelta("Sorry, I could not create the task."), .messageComplete(usage: .init(inputTokens: 20, outputTokens: 10))]
        ]

        let mockRouter = MockToolRouter()
        mockRouter.shouldThrow["todo.create"] = SuperError.toolExecutionFailed(
            toolID: "todo.create", reason: "Database locked"
        )

        let orchestrator = ChatOrchestrator(
            llmService: mockLLM,
            toolRouter: mockRouter,
            messageRepository: MockMessageRepository(),
            conversationRepository: MockConversationRepository(),
            systemPromptBuilder: SystemPromptBuilder()
        )

        var events: [ChatEvent] = []
        let stream = await orchestrator.sendMessage(
            "Add a task",
            in: ConversationRecord(id: "c1", title: nil, createdAt: .now, updatedAt: .now, deletedAt: nil)
        )
        for try await event in stream {
            events.append(event)
        }

        // Tool call should be marked as failed
        XCTAssertTrue(events.contains { if case .toolCallFailed = $0 { return true }; return false })
        // LLM should still get a second turn to explain the failure
        XCTAssertTrue(events.contains { if case .textDelta("Sorry, I could not create the task.") = $0 { return true }; return false })
    }
}
```

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

```swift
final class SystemPromptBuilderTests: XCTestCase {

    func testIncludesAllActiveApplets() {
        let builder = SystemPromptBuilder()
        let prompt = builder.build(
            activeApplets: ["todo", "calendar", "home"],
            tools: [],
            timezone: TimeZone(identifier: "America/Los_Angeles")!,
            recentActivitySummary: nil
        )

        XCTAssertTrue(prompt.contains("todo"))
        XCTAssertTrue(prompt.contains("calendar"))
        XCTAssertTrue(prompt.contains("home"))
    }

    func testIncludesToolDescriptions() {
        let builder = SystemPromptBuilder()
        let tools = [
            LLMTool(id: "todo.create", name: "create", description: "Create a new task", category: .mutation, parameters: [], applet: .todo)
        ]
        let prompt = builder.build(
            activeApplets: ["todo"],
            tools: tools,
            timezone: .current,
            recentActivitySummary: nil
        )

        XCTAssertTrue(prompt.contains("todo.create"))
        XCTAssertTrue(prompt.contains("Create a new task"))
    }

    func testIncludesRecentActivityWhenProvided() {
        let builder = SystemPromptBuilder()
        let prompt = builder.build(
            activeApplets: [],
            tools: [],
            timezone: .current,
            recentActivitySummary: "User completed 3 tasks today."
        )

        XCTAssertTrue(prompt.contains("User completed 3 tasks today."))
    }

    func testOmitsRecentActivityWhenNil() {
        let builder = SystemPromptBuilder()
        let prompt = builder.build(
            activeApplets: [],
            tools: [],
            timezone: .current,
            recentActivitySummary: nil
        )

        XCTAssertFalse(prompt.contains("Recent activity"))
    }
}
```

---

## 14. ChatApplet Conformance

Chat conforms to `SuperApplet` like every other applet, with two distinctions: it registers no tools of its own (it routes to others') and it cannot be uninstalled.

```swift
struct ChatApplet: SuperApplet, Sendable {
    static let appletId = "chat"

    var displayName: String { "Chat" }
    var icon: Image { Image(systemName: "brain") }
    var accentColor: Color { .purple }

    // Chat registers no tools. It is the router, not a tool provider.
    var registeredTools: [LLMTool] { [] }
    var toolExecutor: (any ToolExecutor)? { nil }

    var publishedEvents: [String] { ["aiStreamStarted", "aiToolCallRequested", "aiToolCallCompleted", "aiStreamCompleted"] }
    var subscribedEvents: [String] { ["appletRegistryChanged"] }

    var isRemovable: Bool { false } // Cannot be uninstalled

    @ViewBuilder
    var rootView: some View {
        ChatView()
    }

    func onActivate(eventBus: SuperEventBus, toolRegistry: ToolRegistry) async {
        // Subscribe to applet registry changes to rebuild ToolRouter
        // Start the AppletChangeHandler
    }

    func onDeactivate() {
        // Chat is always active -- this is a no-op
    }

    func onInstall(database: any DatabaseWriter) async throws {
        // Run Chat GRDB migrations
        var migrator = DatabaseMigrator()
        registerChatMigrations(&migrator)
        try migrator.migrate(database)
    }

    func onUninstall() {
        // Unreachable -- Chat cannot be uninstalled
        fatalError("Chat cannot be uninstalled")
    }
}
```

---

## 15. Decision Log

### ADR-BB-001: ChatOrchestrator is an Actor

**Status:** Accepted

**Context:** The orchestrator manages the conversation loop across multiple async operations: LLM streaming, tool execution, and GRDB writes. These operations interleave and mutate shared state (message history, pending tool calls).

**Decision:** `ChatOrchestrator` is an `actor`.

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
