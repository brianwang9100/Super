# Super: Mobile Architecture (iOS / macOS)

> **Prerequisite reading:** `PRODUCT_VISION.md`, `DESIGN.md`
>
> This document covers the native iOS/macOS client architecture. For backend concerns see `SERVER_ARCHITECTURE.md`. For the contract between client and server see `CLIENT_SERVER.md`. For offline-first sync design see `SYNC.md`.

> **Status (2026-05-03):** The Chat applet (`Packages/Chat/`) and the shared `Core` package are built and wired through the composition root in `App/`. Cross-applet plumbing (`SuperEventBus`, `AppletManager`, shared chat-card renderer registry) and other applets remain on the roadmap. Several types referenced in this doc as planned now ship — `ToolRegistration`, `ChatSessionStore`, `ContextAssembler`, `Compactor`, `CompactionCheckpointRecord`, plus the `.thinkingDelta` / `.compactionStarted` / `.compactionCompleted` event variants. Updating this doc to describe them in detail is open work in [`TODO.md`](../TODO.md) § Chat MVP / M12.

---

## Table of Contents

1. [Guiding Constraints](#1-guiding-constraints)
2. [Concurrency & Type Policy](#2-concurrency--type-policy)
3. [Dependency Graph](#3-dependency-graph)
4. [Dependency Injection](#4-dependency-injection)
5. [Event Bus](#5-event-bus)
6. [AI Tool System](#6-ai-tool-system)
7. [LLM Adapter Layer](#7-llm-adapter-layer)
8. [Data Architecture](#8-data-architecture)
9. [Error Handling](#9-error-handling)
10. [Testing Strategy](#10-testing-strategy)
11. [Performance Budget](#11-performance-budget)
12. [Decision Log](#12-decision-log)

---

## 1. Guiding Constraints

Every design decision in the mobile client flows from these non-negotiable constraints:

| # | Constraint | Implication |
|---|-----------|-------------|
| C1 | **Local-first** | The app must be fully functional with no network. All data lives on-device in GRDB; the server is an async replication target, never a runtime dependency. |
| C2 | **Applet independence** | Each applet (Chat, ToDo, Calendar, Home, etc.) is a standalone Swift package. An applet must compile, run, and be tested in complete isolation from every other applet. |
| C3 | **60 fps animations** | No frame drops during transitions, list scrolling, or AI streaming. The animation system gets its own budget and its own scheduling path. |
| C4 | **Strict Swift 6 concurrency** | Zero data races at compile time. `Sendable` is enforced across every boundary. No `@unchecked Sendable` escape hatches in production code. |
| C5 | **AI agent per applet at build time** | Every applet declares the AI tools it supports as part of its package manifest. Tool registration is static and discoverable, not dynamic. |

---

## 2. Concurrency & Type Policy

### 2.1 Swift 6 Strict Concurrency

The entire project compiles with `-strict-concurrency=complete`. The rules are simple and absolute:

- **`async/await` everywhere.** No completion handlers. No Combine publishers for async work (Combine is permitted only for narrow reactive UI bindings where `@Observable` is insufficient).
- **`Sendable` on every type that crosses an isolation boundary.** The compiler enforces this; we do not override it.
- **No `nonisolated(unsafe)`.** No `@unchecked Sendable`.** If the compiler rejects it, redesign the type.

### 2.2 Type Policy Table

| Kind of thing | Use | Why |
|--------------|-----|-----|
| Data (models, DTOs, events) | `struct` | Value semantics, automatic `Sendable`, no reference cycles |
| Identity (database connections, network sessions, caches) | `class` | Needs reference identity and deinit lifecycle |
| Shared mutable state | `actor` | Compiler-enforced isolation, no manual locking |
| Hot-path shared state (< 5 fields, no async) | `os_unfair_lock` | Actors have hop overhead; locks don't. Justified only with a benchmark. |
| UI state | `@Observable class` on `@MainActor` | SwiftUI observation, main-actor isolation, fine-grained updates |
| UI views | `struct` (SwiftUI `View`) | Required by SwiftUI |

### 2.3 Scenario Table

| Scenario | Mechanism | Notes |
|----------|-----------|-------|
| ViewModel reads/writes UI state | `@MainActor @Observable class` | All published properties on main actor |
| ViewModel calls a service | `await service.doWork()` | Service may be an actor or nonisolated async func |
| Service writes to DB | `try await db.write { ... }` | GRDB's write is already async-safe |
| Event bus dispatches to subscriber | `actor` isolation + `@MainActor` callback | Bus is an actor; subscriber closures are `@MainActor @Sendable` |
| Background AI tool execution | `Task.detached(priority: .userInitiated)` | Only for CPU-bound tool execution; result hops back to main actor |
| Animation scheduling | `@MainActor`, `CADisplayLink` wrapper | Never leaves main actor |

---

## 3. Dependency Graph

### 3.1 Package Dependency Rules

1. **The shell imports applets.** Applets never import each other.
2. **Applets import Core packages.** Core packages never import applets.
3. **Core packages may import other Core packages** following a strict DAG (no cycles).
4. **No applet depends on another applet**, even transitively.

### 3.2 High-Level Diagram

```
┌─────────────────────────────────────────────────┐
│                  Super Shell                  │
│  (app target, composition root, tab router)     │
├─────────┬──────────┬──────────┬─────────────────┤
│ Chat│  ToDo   │  Calendar  │   Home  ...  │
│ (chat)  │ (todos)  │(calendar)│ (home asst)     │
├─────────┴──────────┴──────────┴─────────────────┤
│                  Core Packages                   │
│  ┌──────────┐ ┌──────────┐ ┌──────────────────┐ │
│  │ EventBus │ │AppletKit │ │   Networking     │ │
│  ├──────────┤ ├──────────┤ ├──────────────────┤ │
│  │ Storage  │ │Animation │ │  DesignSystem    │ │
│  ├──────────┤ ├──────────┤ ├──────────────────┤ │
│  │Utilities │ │          │ │                  │ │
│  └──────────┘ └──────────┘ └──────────────────┘ │
└─────────────────────────────────────────────────┘
```

### 3.3 Core Package Structure

```
Core/
├── EventBus/          # SuperEventBus actor, event types, subscriber API
├── AppletKit/         # Applet protocol, lifecycle, tool registration
├── Networking/        # LLM adapter layer, HTTP client, auth
├── Storage/           # GRDB wrapper, DatabaseContainer, migration helpers
├── Animation/         # Spring configs, transition library, display-link scheduler
├── DesignSystem/      # Tokens, components, typography, color
└── Utilities/         # CircularBuffer, extensions, logging, feature flags
```

### 3.4 Applet Internal Structure

Every applet follows the same four-layer structure. Dependencies flow **downward only**.

```
ToDo/
├── Domain/            # Models (struct), enums, protocols
│   ├── Models/        #   e.g. TodoItem, TodoList, Priority
│   └── Protocols/     #   e.g. TaskRepository (protocol)
├── Data/              # Persistence, network DTOs
│   ├── Repository/    #   e.g. GRDBTaskRepository: TaskRepository
│   ├── Migration/     #   GRDB migration definitions
│   └── DTO/           #   Codable network types
├── Service/           # Business logic, AI tool executors
│   ├── TaskService.swift
│   └── Tools/         #   AI tool definitions & executors
└── UI/                # SwiftUI views, ViewModels
    ├── ViewModels/    #   @Observable @MainActor classes
    ├── Views/         #   SwiftUI view structs
    └── Components/    #   Reusable applet-specific UI
```

**Layer rules:**

| Layer | May import | Must not import |
|-------|-----------|----------------|
| Domain | Nothing (pure Swift + Foundation) | Data, Service, UI |
| Data | Domain | Service, UI |
| Service | Domain, Data | UI |
| UI | Domain, Service | Data (never talks to repositories directly) |

---

## 4. Dependency Injection

### 4.1 Principles

- **Environment-based DI.** SwiftUI's `@Environment` is the injection mechanism.
- **No third-party DI container.** No Swinject, no Factory, no Needle. The shell's composition root is the container.
- **Protocol-based boundaries.** Services are injected as protocol types, enabling test doubles.

### 4.2 Shell-Level Injection (Composition Root)

The shell app is the single place where real implementations are wired together:

```swift
@main
struct SuperOSApp: App {
    @State private var eventBus = SuperEventBus()
    @State private var providerRegistry = ProviderRegistry()
    @State private var toolRegistry = ToolRegistry()

    var body: some Scene {
        WindowGroup {
            SuperOSContentView()
                .environment(eventBus)
                .environment(providerRegistry)
                .environment(toolRegistry)
                .environment(
                    ToDoService(
                        db: DatabaseContainer.todo,
                        eventBus: eventBus,
                        toolRegistry: toolRegistry
                    ) as any TaskManaging
                )
                .environment(
                    CalendarService(
                        db: DatabaseContainer.calendar,
                        eventBus: eventBus
                    ) as any CalendarManaging
                )
        }
    }
}
```

### 4.3 Applet-Level Injection

Each applet's root view pulls dependencies from the environment and constructs its view model:

```swift
struct ToDoRootView: View {
    @Environment(\.taskService) private var taskService
    @Environment(SuperEventBus.self) private var eventBus
    @State private var viewModel: ToDoViewModel?

    var body: some View {
        Group {
            if let viewModel {
                TaskListView(viewModel: viewModel)
            } else {
                ProgressView()
            }
        }
        .task {
            viewModel = ToDoViewModel(
                service: taskService,
                eventBus: eventBus
            )
        }
    }
}
```

### 4.4 Testing Overrides

Tests inject mock implementations via the same protocol boundaries:

```swift
final class MockTaskService: TaskManaging, @unchecked Sendable {
    var createTaskCalled = false
    var lastCreatedTask: TodoItem?

    func createTask(_ task: TodoItem) async throws {
        createTaskCalled = true
        lastCreatedTask = task
    }
    // ...
}
```

> **Note:** `@unchecked Sendable` is permitted **only** in test targets for mock types.

---

## 5. Event Bus

### 5.1 Why an Actor

The event bus is the sole communication channel between applets. It must be:

- Thread-safe (multiple applets subscribe/publish concurrently)
- Non-blocking (publishing must not wait for subscribers)
- Replay-capable (late subscribers need recent events for consistency)

An `actor` satisfies all three by design.

### 5.2 Implementation

```swift
actor SuperEventBus {
    private var subscribers: [ObjectIdentifier: [EventSubscription]] = [:]
    private var replayBuffer: CircularBuffer<SuperEvent>

    init(replayCapacity: Int = 64) {
        self.replayBuffer = CircularBuffer(capacity: replayCapacity)
    }

    func publish(_ event: SuperEvent) {
        replayBuffer.append(event)
        let snapshot = subscribers.values.flatMap { $0 }
        for subscription in snapshot {
            guard subscription.filter(event) else { continue }
            Task { @MainActor in
                subscription.handler(event)
            }
        }
    }

    func subscribe(
        owner: AnyObject,
        filter: @escaping @Sendable (SuperEvent) -> Bool = { _ in true },
        handler: @escaping @MainActor @Sendable (SuperEvent) -> Void
    ) {
        let id = ObjectIdentifier(owner)
        let sub = EventSubscription(filter: filter, handler: handler)
        subscribers[id, default: []].append(sub)

        // Replay buffered events that match the filter
        for event in replayBuffer where filter(event) {
            Task { @MainActor in
                handler(event)
            }
        }
    }

    func unsubscribe(owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        subscribers.removeValue(forKey: id)
    }
}
```

### 5.3 Event Categories

```swift
enum SuperEvent: Sendable {
    // Applet data events
    case applet(AppletEvent)

    // AI events
    case aiStreamStarted(applet: AppletID)
    case aiStreamChunk(applet: AppletID, text: String)
    case aiStreamCompleted(applet: AppletID)
    case aiToolCallRequested(applet: AppletID, tool: String, input: [String: Any])
    case aiToolCallCompleted(applet: AppletID, tool: String, result: ToolResult)

    // Animation events
    case animationRequested(AnimationEvent)
    case animationCompleted(AnimationEvent)

    // Notification events
    case notificationScheduled(id: String, date: Date)
    case notificationFired(id: String)

    // System events
    case appDidBecomeActive
    case appWillResignActive
    case appDidEnterBackground
    case syncCompleted(applet: AppletID)
    case errorOccurred(SuperError)
}
```

### 5.4 AppletEvent (Generic Cross-Applet Data Events)

```swift
enum AppletEvent: Sendable {
    case dataCreated(applet: AppletID, entityType: String, entityID: String)
    case dataUpdated(applet: AppletID, entityType: String, entityID: String)
    case dataDeleted(applet: AppletID, entityType: String, entityID: String)
}
```

These generic events allow applets to react to changes in other applets without importing them. For example, Calendar can listen for `dataCreated(applet: .todo, entityType: "TodoItem", ...)` to create a calendar entry for a task with a due date.

### 5.5 Threading Model

| Operation | Thread/Isolation | Why |
|-----------|-----------------|-----|
| `publish()` | Actor-isolated | Protects `subscribers` and `replayBuffer` |
| Subscriber handler execution | `@MainActor` | Handlers update `@Observable` ViewModels which drive UI |
| `subscribe()` / `unsubscribe()` | Actor-isolated | Mutates subscriber dictionary |
| Replay delivery | `@MainActor` via `Task` | Same as normal delivery |

### 5.6 Subscriber Pattern in ViewModel

```swift
@Observable
@MainActor
final class ToDoViewModel {
    private let service: any TaskManaging
    private let eventBus: SuperEventBus
    var tasks: [TodoItem] = []
    var isLoading = false

    init(service: any TaskManaging, eventBus: SuperEventBus) {
        self.service = service
        self.eventBus = eventBus
    }

    func start() async {
        isLoading = true
        tasks = (try? await service.allTasks()) ?? []
        isLoading = false

        await eventBus.subscribe(owner: self, filter: { event in
            if case .applet(.dataCreated(applet: .todo, _, _)) = event { return true }
            if case .applet(.dataUpdated(applet: .todo, _, _)) = event { return true }
            if case .applet(.dataDeleted(applet: .todo, _, _)) = event { return true }
            return false
        }, handler: { [weak self] _ in
            guard let self else { return }
            self.tasks = (try? await self.service.allTasks()) ?? []
        })
    }

    deinit {
        // Note: unsubscribe must be called explicitly before deinit
        // because deinit cannot call async actor methods
    }
}
```

### 5.7 Event Bus Rules

1. **Events are fire-and-forget.** Publishers never wait for subscriber acknowledgment.
2. **Events are value types.** Every case payload must be `Sendable`.
3. **No event chains.** A subscriber must not publish a new event inside its handler (prevents cascading loops). If a reaction is needed, schedule it in a new `Task`.
4. **Replay buffer is bounded.** Default 64 events. Old events are silently dropped.
5. **Unsubscribe is the caller's responsibility.** Typically done in the ViewModel's teardown path.

---

## 6. AI Tool System

### 6.1 Tool Definition

```swift
struct LLMTool: Sendable, Identifiable {
    let id: String                          // e.g. "todo.create_task"
    let name: String                        // e.g. "create_task"
    let description: String                 // Shown to the LLM
    let category: LLMToolCategory
    let parameters: [LLMToolParameter]
    let applet: AppletID
}

struct LLMToolParameter: Sendable {
    let name: String
    let type: ParameterType                 // .string, .int, .bool, .array, .object
    let description: String
    let isRequired: Bool
    let enumValues: [String]?               // For constrained choices
}

enum LLMToolCategory: String, Sendable {
    case query                              // Read-only, safe to auto-execute
    case mutation                           // Creates/modifies data
    case navigation                         // Changes visible UI
    case system                             // App-level operations
}
```

### 6.2 Tool Registration & Discovery

```swift
actor ToolRegistry {
    private var tools: [String: LLMTool] = [:]
    private var executors: [String: any ToolExecutor] = [:]

    func register(tool: LLMTool, executor: any ToolExecutor) {
        tools[tool.id] = tool
        executors[tool.id] = executor
    }

    func tools(for applet: AppletID) -> [LLMTool] {
        tools.values.filter { $0.applet == applet }
    }

    func allTools() -> [LLMTool] {
        Array(tools.values)
    }

    func executor(for toolID: String) -> (any ToolExecutor)? {
        executors[toolID]
    }
}
```

Each applet registers its tools at startup (typically in its root view's `.task` modifier or via an `AppletKit`-provided lifecycle hook). Registration is static and exhaustive -- the set of tools an applet provides is known at build time.

### 6.3 Tool Execution Flow

```
User message
    │
    ▼
┌──────────────┐
│  LLM Adapter │  ← Sends tools list as part of request
│  (streaming) │
└──────┬───────┘
       │ stream yields tool_use block
       ▼
┌──────────────┐
│  Validate    │  ← Check required params, types, enum values
│  Parameters  │
└──────┬───────┘
       │ valid
       ▼
┌──────────────┐
│ ToolRegistry │  ← Look up executor by tool ID
│  .executor() │
└──────┬───────┘
       │ found
       ▼
┌──────────────┐
│ ToolExecutor │  ← Execute with validated input
│  .execute()  │
└──────┬───────┘
       │ ToolResult
       ▼
┌──────────────┐
│  LLM Adapter │  ← Send tool_result back, continue generation
│  (continue)  │
└──────────────┘
```

### 6.4 ToolExecutor Protocol

```swift
protocol ToolExecutor: Sendable {
    var toolID: String { get }
    func execute(input: [String: Any]) async throws -> ToolResult
}

struct ToolResult: Sendable {
    let toolID: String
    let content: String          // Stringified result sent back to the LLM
    let isError: Bool
    let artifacts: [Artifact]    // Optional structured data (e.g., created entity IDs)

    struct Artifact: Sendable {
        let type: String         // e.g. "todo_item", "calendar_event"
        let id: String
        let data: [String: String]
    }
}
```

### 6.5 Example: ToDo Tool Executor

```swift
struct CreateTaskExecutor: ToolExecutor {
    let toolID = "todo.create_task"
    let service: any TaskManaging

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let title = input["title"] as? String else {
            return ToolResult(toolID: toolID, content: "Missing required parameter: title", isError: true, artifacts: [])
        }

        let priority = (input["priority"] as? String).flatMap(Priority.init) ?? .medium
        let dueDate = (input["due_date"] as? String).flatMap(ISO8601DateFormatter().date)

        let task = TodoItem(title: title, priority: priority, dueDate: dueDate)
        try await service.createTask(task)

        return ToolResult(
            toolID: toolID,
            content: "Created task: \(title)",
            isError: false,
            artifacts: [.init(type: "todo_item", id: task.id.uuidString, data: ["title": title])]
        )
    }
}
```

---

## 7. LLM Adapter Layer

### 7.1 LLMProvider Protocol

```swift
protocol LLMProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var supportedModels: [LLMModel] { get }

    func stream(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double
    ) -> AsyncThrowingStream<LLMStreamEvent, Error>
}
```

### 7.2 Stream Event Normalization

All providers emit the same event type regardless of their native wire format:

```swift
enum LLMStreamEvent: Sendable {
    case messageStart(id: String, model: String)
    case contentBlockStart(index: Int, type: ContentBlockType)
    case textDelta(index: Int, text: String)
    case toolUse(index: Int, id: String, name: String, input: [String: Any])
    case contentBlockStop(index: Int)
    case messageComplete(usage: TokenUsage)
    case error(LLMError)

    enum ContentBlockType: Sendable {
        case text
        case toolUse
    }

    struct TokenUsage: Sendable {
        let inputTokens: Int
        let outputTokens: Int
    }
}
```

### 7.3 Provider Implementations

```
Networking/
├── LLMProvider.swift            # Protocol
├── LLMStreamEvent.swift         # Normalized event enum
├── Providers/
│   ├── ClaudeProvider.swift      # Anthropic Messages API
│   ├── OpenClawProvider.swift    # OpenAI-compatible API
│   └── LocalProvider.swift       # On-device models (future)
└── ProviderRegistry.swift        # Runtime provider selection
```

### 7.4 Provider Selection

```swift
actor ProviderRegistry {
    private var providers: [String: any LLMProvider] = [:]
    private var activeProviderID: String?

    func register(_ provider: any LLMProvider) {
        providers[provider.id] = provider
    }

    func activeProvider() throws -> any LLMProvider {
        guard let id = activeProviderID, let provider = providers[id] else {
            throw SuperError.noActiveProvider
        }
        return provider
    }

    func setActive(_ providerID: String) {
        activeProviderID = providerID
    }
}
```

### 7.5 Tool-Calling Convention Differences

The adapter layer normalizes these differences so applet code never sees provider-specific formats:

| Concern | Claude (Anthropic) | Open Claw (OpenAI-compatible) |
|---------|-------------------|-------------------------------|
| Tool definition format | `input_schema` (JSON Schema) | `parameters` (JSON Schema) |
| Tool use in response | `tool_use` content block with `id`, `name`, `input` | `tool_calls` array with `id`, `function.name`, `function.arguments` (JSON string) |
| Tool result submission | `tool_result` content block with `tool_use_id` | `tool` role message with `tool_call_id` |
| Streaming tool args | Incremental JSON deltas in `input_json_delta` | Incremental string deltas in `function.arguments` |
| Multiple tool calls | Multiple `tool_use` blocks in one message | `tool_calls` array with multiple entries |

---

## 8. Data Architecture

### 8.1 Per-Applet GRDB Databases

Each applet owns its own SQLite database. No applet can read or write another applet's database. This enforces data independence at the filesystem level.

```swift
enum DatabaseContainer {
    static var todo: DatabaseWriter {
        makeWriter(for: "todo.sqlite")
    }

    static var calendar: DatabaseWriter {
        makeWriter(for: "calendar.sqlite")
    }

    static var chat: DatabaseWriter {
        makeWriter(for: "chat.sqlite")
    }

    static var home: DatabaseWriter {
        makeWriter(for: "home.sqlite")
    }

    private static func makeWriter(for filename: String) -> DatabaseWriter {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Super", isDirectory: true)
            .appendingPathComponent(filename)

        var config = Configuration()
        config.prepareDatabase { db in
            db.trace { log in
                #if DEBUG
                print("[SQL] \(log)")
                #endif
            }
        }

        let writer = try! DatabasePool(path: url.path, configuration: config)
        return writer
    }
}
```

### 8.2 GRDB Companion Packages

#### [GRDBQuery](https://github.com/groue/GRDBQuery) (Reactive SwiftUI)

`GRDBQuery` (`https://github.com/groue/GRDBQuery`) is the canonical bridge between GRDB and SwiftUI for Super. Views subscribe to database queries via the `@Query` property wrapper and re-render automatically when the underlying data changes. This is the only sanctioned reactive-binding mechanism for GRDB → SwiftUI in this project — do not hand-roll `ValueObservation` plumbing in view models when a `@Query` will do.

```swift
struct TaskListView: View {
    @Query(TaskListRequest()) private var tasks: [TodoItem]

    var body: some View {
        List(tasks) { task in
            TaskRow(task: task)
        }
    }
}

struct TaskListRequest: ValueObservationQueryable {
    static var defaultValue: [TodoItem] { [] }

    func fetch(_ db: Database) throws -> [TodoItem] {
        try TodoItem
            .order(Column("priority").desc)
            .fetchAll(db)
    }
}
```

#### GRDBSnapshotTesting

Snapshot testing for database state, ensuring migrations and queries produce expected results:

```swift
func testMigration_v2_addsPriorityColumn() throws {
    let db = try DatabaseQueue()

    // Apply migrations up to v1
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
        try db.create(table: "todoItem") { t in
            t.primaryKey("id", .text)
            t.column("title", .text).notNull()
        }
    }
    try migrator.migrate(db)

    // Insert v1 data
    try db.write { db in
        try db.execute(sql: "INSERT INTO todoItem (id, title) VALUES (?, ?)",
                       arguments: ["1", "Buy milk"])
    }

    // Apply v2 migration
    migrator.registerMigration("v2") { db in
        try db.alter(table: "todoItem") { t in
            t.add(column: "priority", .text).defaults(to: "medium")
        }
    }
    try migrator.migrate(db)

    // Snapshot the result
    let items = try db.read { try Row.fetchAll($0, sql: "SELECT * FROM todoItem") }
    assertSnapshot(matching: items, as: .dump)
}
```

### 8.3 Cross-Applet Data Access via Event-Driven Projections

Applets never query each other's databases. Instead, they maintain **local projections** of external data by subscribing to events on the event bus.

**Example: Calendar maintains a projection of ToDo deadlines**

```swift
/// A lightweight projection of a ToDo task's due date,
/// stored in Calendar's own database.
struct ExternalDeadline: Codable, FetchableRecord, PersistableRecord, Sendable {
    let sourceApplet: String      // "todo"
    let sourceEntityID: String    // TodoItem.id
    let title: String
    let deadline: Date

    static let databaseTableName = "externalDeadline"
}

// In Calendar's startup:
await eventBus.subscribe(owner: self, filter: { event in
    if case .applet(.dataCreated(applet: .todo, entityType: "TodoItem", _)) = event {
        return true
    }
    if case .applet(.dataUpdated(applet: .todo, entityType: "TodoItem", _)) = event {
        return true
    }
    if case .applet(.dataDeleted(applet: .todo, entityType: "TodoItem", _)) = event {
        return true
    }
    return false
}, handler: { [weak self] event in
    guard let self else { return }
    await self.syncExternalDeadline(from: event)
})
```

The event payload carries enough information (entity type + ID) for Calendar to request the relevant data through a well-defined cross-applet query service (exposed via the shell, not by direct database access).

### 8.4 Schema Migration Strategy

Each applet uses GRDB's `DatabaseMigrator` with ordered, named migrations:

```swift
var migrator = DatabaseMigrator()

migrator.registerMigration("v1_createTasks") { db in
    try db.create(table: "todoItem") { t in
        t.primaryKey("id", .text)
        t.column("title", .text).notNull()
        t.column("isCompleted", .boolean).notNull().defaults(to: false)
        t.column("createdAt", .datetime).notNull()
    }
}

migrator.registerMigration("v2_addPriority") { db in
    try db.alter(table: "todoItem") { t in
        t.add(column: "priority", .text).defaults(to: "medium")
    }
}

migrator.registerMigration("v3_addDueDate") { db in
    try db.alter(table: "todoItem") { t in
        t.add(column: "dueDate", .datetime)
    }
    try db.create(index: "todoItem_on_dueDate", on: "todoItem", columns: ["dueDate"])
}

try migrator.migrate(writer)
```

**Migration rules:**

- Migrations are append-only. Never modify a shipped migration.
- Every migration has a descriptive name (`v3_addDueDate` not `migration3`).
- Destructive changes (drop column, drop table) require a two-step migration across releases.

---

## 9. Error Handling

### 9.1 SuperError Enum

```swift
enum SuperError: Error, Sendable {
    // Data
    case databaseError(underlying: Error)
    case entityNotFound(type: String, id: String)
    case migrationFailed(version: String, underlying: Error)

    // Network
    case networkUnavailable
    case serverError(statusCode: Int, body: String)
    case authenticationExpired

    // AI / LLM
    case noActiveProvider
    case providerError(provider: String, underlying: Error)
    case toolNotFound(toolID: String)
    case toolExecutionFailed(toolID: String, reason: String)
    case invalidToolParameters(toolID: String, details: String)

    // System
    case appletNotFound(AppletID)
    case featureFlagDisabled(String)
}
```

### 9.2 Error Handling Strategy

| Layer | Strategy | Example |
|-------|----------|---------|
| **View** | Show inline error state, offer retry | `ErrorBanner(message:retryAction:)` |
| **ViewModel** | Catch, map to user-visible message, set error state | `catch { self.error = .userMessage(from: error) }` |
| **Service** | Throw domain errors, never swallow silently | `throw SuperError.entityNotFound(...)` |
| **Data** | Wrap database errors, add context | `catch { throw SuperError.databaseError(underlying: error) }` |
| **Event Bus** | Publish `.errorOccurred` for system-wide visibility | `await eventBus.publish(.errorOccurred(error))` |

### 9.3 Crash Recovery

- GRDB uses WAL mode by default, providing crash-resilient writes.
- On launch, each applet's `DatabaseMigrator` runs `migrate()` which is idempotent. If the app crashed mid-migration, the incomplete transaction was rolled back by SQLite.
- The event bus replay buffer is in-memory only. After a crash, applets re-read their own databases on startup and do not rely on replayed events for correctness.

---

## 10. Testing Strategy

### 10.1 Test Pyramid

```
          ┌──────────┐
          │   E2E    │   XCUITest: critical user flows only
          │  (few)   │   (~10 tests per applet)
         ┌┴──────────┴┐
         │ Integration │  Real GRDB in-memory DB + mock network
         │ (moderate)  │  (~50 tests per applet)
        ┌┴────────────┴┐
        │    Unit       │  Pure functions, ViewModels with mocks
        │   (many)      │  (~200+ tests per applet)
        └──────────────┘
```

### 10.2 Testing Boundaries

| What | How | Isolation |
|------|-----|-----------|
| Domain models | Pure unit tests | No dependencies |
| ViewModel logic | Mock services, real event bus (in-memory) | `@MainActor` test methods |
| Service logic | In-memory GRDB, mock network | Real DB, fake HTTP |
| AI tool execution | Mock service layer, assert `ToolResult` | No LLM, no network |
| Event bus integration | Real `SuperEventBus`, verify events published/received | In-process actor |
| GRDB migrations | `DatabaseQueue()` in-memory, apply migrations, assert schema | No filesystem |
| Cross-applet projection | Real event bus + in-memory DBs for both applets | No filesystem |

### 10.3 Applet Isolation in Tests

Because applets are separate Swift packages, each applet's test target compiles independently. A ToDo test never imports Calendar. Cross-applet behavior is tested only at the shell level (integration/E2E).

```swift
// ToDoTests/CreateTaskTests.swift
@MainActor
func test_createTask_publishesEvent() async throws {
    let eventBus = SuperEventBus()
    let db = try DatabaseQueue()  // in-memory
    let repo = GRDBTaskRepository(db: db)
    let service = TaskService(repository: repo, eventBus: eventBus)

    var receivedEvents: [SuperEvent] = []
    await eventBus.subscribe(owner: self) { event in
        receivedEvents.append(event)
    }

    let task = TodoItem(title: "Buy milk", priority: .high)
    try await service.createTask(task)

    // Assert the event was published
    XCTAssertEqual(receivedEvents.count, 1)
    if case .applet(.dataCreated(applet: .todo, entityType: "TodoItem", let id)) = receivedEvents[0] {
        XCTAssertEqual(id, task.id.uuidString)
    } else {
        XCTFail("Expected dataCreated event")
    }

    // Assert the task is persisted
    let fetched = try await repo.fetch(id: task.id)
    XCTAssertEqual(fetched?.title, "Buy milk")
}
```

### 10.4 AI Tool Testing

```swift
func test_createTaskTool_withValidInput() async throws {
    let mockService = MockTaskService()
    let executor = CreateTaskExecutor(service: mockService)

    let result = try await executor.execute(input: [
        "title": "Buy milk",
        "priority": "high",
        "due_date": "2026-03-20T10:00:00Z"
    ])

    XCTAssertFalse(result.isError)
    XCTAssertTrue(result.content.contains("Buy milk"))
    XCTAssertTrue(mockService.createTaskCalled)
    XCTAssertEqual(mockService.lastCreatedTask?.priority, .high)
}

func test_createTaskTool_missingTitle_returnsError() async throws {
    let mockService = MockTaskService()
    let executor = CreateTaskExecutor(service: mockService)

    let result = try await executor.execute(input: ["priority": "low"])

    XCTAssertTrue(result.isError)
    XCTAssertTrue(result.content.contains("Missing required parameter"))
    XCTAssertFalse(mockService.createTaskCalled)
}
```

---

## 11. Performance Budget

### 11.1 Client Performance Targets

| Metric | Target | Measurement |
|--------|--------|-------------|
| App launch to interactive | < 800ms | `os_signpost` from `didFinishLaunching` to first frame |
| Tab switch (applet swap) | < 100ms | Time from tab tap to new applet's first frame |
| List scroll frame rate | 60 fps (no drops) | Instruments Core Animation profiler |
| AI stream first token visible | < 200ms after network response | `os_signpost` from stream open to first `textDelta` rendered |
| Database query (typical list) | < 10ms | GRDB `trace` logging in debug |
| Event bus publish-to-handler | < 5ms | In-process actor hop + main actor dispatch |

### 11.2 Strategies

**Lazy applet initialization.** Applet modules are imported at build time, but their databases, services, and ViewModels are not created until the user navigates to that applet's tab for the first time.

**Pagination.** All list views use GRDB's `LIMIT/OFFSET` or cursor-based pagination. No view ever loads an unbounded result set.

**Lazy loading.** Heavy assets (images, file attachments) are loaded on-demand with placeholder views. SwiftUI's `LazyVStack` and `LazyHStack` are preferred over eager equivalents.

**Background processing.** Sync operations, projection updates, and AI tool executions that don't need immediate UI feedback run on background priorities via structured concurrency (`Task(priority: .utility)`).

**Animation budget.** Animations are capped at 16ms per frame. Complex transitions use pre-computed spring parameters from the `Animation` core package. The display-link scheduler drops animations rather than accumulating frame debt.

---

## 12. Decision Log

### ADR-001: Native SwiftUI Over Cross-Platform

**Status:** Accepted

**Context:** Evaluated React Native, Flutter, and KMP for shared UI. Super targets iOS and macOS only (not Android).

**Decision:** Pure SwiftUI with platform-conditional modifiers for macOS differences.

**Consequences:** Maximum access to platform APIs (Shortcuts, WidgetKit, Live Activities). No bridging overhead. Team must be Swift-fluent. No Android target.

---

### ADR-003: Per-Applet GRDB Databases

**Status:** Accepted

**Context:** Could use a single shared database, Core Data, or Realm.

**Decision:** Each applet owns a separate `.sqlite` file managed by GRDB.

**Consequences:** Applets are truly isolated at the data layer. Schema migrations are per-applet. Cross-applet queries are impossible by design (must use event-driven projections). GRDB gives raw SQL escape hatches when the ORM is insufficient. See [Section 8](#8-data-architecture) for details.

---

### ADR-004: Event-Driven Cross-Applet Communication

**Status:** Accepted

**Context:** Applets need to react to each other's data changes without importing each other.

**Decision:** A central `SuperEventBus` actor. Applets publish domain events; other applets subscribe and maintain local projections.

**Consequences:** No compile-time coupling between applets. Eventual consistency (projections update asynchronously). Debugging cross-applet flows requires event tracing. See [Section 5](#5-event-bus).

---

### ADR-005: Provider-Agnostic LLM Layer

**Status:** Accepted

**Context:** Must support Claude, OpenAI-compatible providers, and potentially on-device models.

**Decision:** `LLMProvider` protocol with normalized `LLMStreamEvent`. Provider-specific wire formats are translated at the adapter boundary.

**Consequences:** Adding a new provider requires only a new conformance. Applet code never sees provider-specific types. Tool-calling convention differences are hidden. See [Section 7](#7-llm-adapter-layer).

---

### ADR-007: Client-Side Tool Execution

**Status:** Accepted

**Context:** AI tools could execute on the server (proxied) or on the client.

**Decision:** Tools execute on-device. The LLM returns a tool-use request; the client validates parameters, executes via `ToolExecutor`, and sends the result back.

**Consequences:** Tools have full access to local data (GRDB). No server round-trip for tool execution. Tool set is known at build time. Sensitive data never leaves the device for tool operations. See [Section 6](#6-ai-tool-system).

---

### ADR-008: @Observable State Management

**Status:** Accepted

**Context:** Evaluated `@Published`/`ObservableObject`, Combine, TCA, and `@Observable`.

**Decision:** `@Observable` (Observation framework) for all ViewModel state. No TCA. No Combine for state management.

**Consequences:** Fine-grained SwiftUI updates (only views reading changed properties re-render). Simpler than `ObservableObject` (no `@Published` boilerplate). Requires iOS 17+ / macOS 14+. ViewModels are `@Observable @MainActor` classes.

---

### ADR-011: Strict Swift 6 Concurrency From Day One

**Status:** Accepted

**Context:** Could adopt strict concurrency incrementally or all at once.

**Decision:** All packages compile with `-strict-concurrency=complete` from the first commit. No `@unchecked Sendable` in production code.

**Consequences:** Data races caught at compile time. Higher initial friction for developers unfamiliar with Sendable constraints. Forces clean isolation boundaries. Actors are the default for shared mutable state. See [Section 2](#2-concurrency--type-policy).

---

*Last updated: 2026-03-16*
