# Super — Agent Guidelines

## Documentation

All design documents live in `docs/`. Read the relevant docs before working on any component:

- `PRODUCT_VISION.md` — overall vision, applet breakdown, principles
- `DESIGN.md` — app shell, applet manager, navigation layouts
- `MOBILE_ARCHITECTURE.md` — dependency graph, event bus, data layer, tool system, LLM adapter
- `SERVER_ARCHITECTURE.md` — gateway, per-applet services, admin dashboard
- `CLIENT_SERVER.md` — sync vs REST, API routing, Chat orchestration
- `SYNC.md` — platform-agnostic sync engine
- `AUTH.md` — username/password, JWT tokens, admin account setup
- `CI_PIPELINE.md` — CI/CD, AI agent workflow, automated PR review
- `OBSERVABILITY.md` — metrics, crash reporting, analytics, logging
- `SECURITY.md` — threat model, encryption, auth, home automation safety
- `AI_TOOLS.md` — approved AI development tools and security rules
- `CHAT_INTERACTIONS.md` — cross-applet interaction catalog
- `DEVELOPMENT_SETUP.md` — clone, build, deploy, first-run wizard
- `Chat/` — Chat (AI chatbot) applet-specific design and architecture

## Terminology

- **Applet** = an individual app within Super (Chat, ToDo, Calendar, Home, etc.)
- **Module** = a Swift Package Manager code module (not the same as an applet)
- **Shell** = the Super app container that hosts applets

## File & Folder Naming

Follow the convention of the platform you're on.

- **Markdown files (everywhere)**: `UPPER_SNAKE_CASE.md` (e.g., `PRODUCT_VISION.md`, `MOBILE_ARCHITECTURE.md`). Exception: `README.md` where convention dictates.
- **iOS / macOS (Swift)**: `PascalCase` for files and folders. Examples: `ChatOrchestrator.swift`, `ChatDatabase.swift`, `Packages/Chat/`, `Sources/Domain/`, `docs/Chat/`.
- **Server (TypeScript / Node.js)**: `lowercase` (kebab-case for multi-word) for files and folders. Examples: `src/gateway/`, `src/services/ai/`, `src/modules/sync/`, `route-handlers.ts`. TypeScript classes/types inside files still use `PascalCase` per language convention.
- **Doc subdirectories** follow the platform they describe: `docs/Chat/` (iOS applet), `docs/server/` would be lowercase (if ever created).

## Swift Concurrency & Type Policy

### Structs for data, classes for identity

- **Structs** for anything that is pure data: models, events, tool definitions, DTOs, configuration, API payloads
- **Classes** only for objects that own state, manage a resource, or where there should be exactly one instance:
  - `actor` — shared mutable state (EventBus, ToolRegistry, AuthInterceptor)
  - `@Observable @MainActor final class` — SwiftUI view models
  - `final class` with `os_unfair_lock` — synchronous atomic access
- If a type doesn't clearly own state or represent a singular resource, it's a struct

### Strict concurrency

- Swift 6 strict concurrency enabled on all targets
- `async/await` everywhere — no completion handler callbacks
- No Combine for data flow — use `AsyncStream`/`AsyncSequence`
- All types crossing concurrency boundaries must be `Sendable`
- `@MainActor` on all view models and UI-bound state

### Synchronization

- **Actors** by default for shared mutable state
- **`os_unfair_lock`** when a multi-step mutation must be atomic (actor reentrancy risk)
- Never use `DispatchQueue` or `NSLock` for synchronization

## Persistence

- **GRDB** (not SwiftData/Core Data) for all persistence
- All data models are `struct` conforming to `Codable, FetchableRecord, PersistableRecord, Sendable`
- Each applet gets its own `.sqlite` file via `DatabaseQueue`
- Use `DatabaseMigrator` with explicit SQL for schema migrations
- Use **GRDBQuery** for reactive SwiftUI data binding (`ValueObservation`)
- Use **GRDBSnapshotTesting** for snapshot testing of database state

### GRDB Naming Conventions

Match GRDB's association-inference rules so relationships are synthesized automatically:

- **Table names**: `camelCase`, singular (e.g., `task`, `toolCall`, `syncLog`). Set via `static let databaseTableName = "toolCall"`.
- **Column names**: `camelCase` matching the Swift property name exactly (e.g., `createdAt`, `conversationId`). No `CodingKeys` mapping required.
- **Primary key**: `id` (String UUID).
- **Foreign keys**: `<referencedTableSingular>Id` (e.g., `conversationId` → `conversation.id`, `messageId` → `message.id`). This naming lets GRDB auto-synthesize `belongsTo` / `hasMany` associations without explicit keys.
- **Timestamp columns**: `createdAt`, `updatedAt`, `deletedAt`, `completedAt` — always `camelCase`, always `.datetime` (or `TIMESTAMPTZ` on server).
- **Indexes**: `<tableName>_on_<column>[_<column>]` (e.g., `message_on_conversationId_createdAt`). The underscore separators are intentional — they denote the "on" pattern, not snake_case.

**Server-side Postgres is different.** Drizzle schemas use `snake_case` per Postgres convention (e.g., `sync_changes`, `user_id`). The sync protocol maps between the two at the JSON boundary. Do not apply GRDB naming to Postgres tables.

## Architecture Rules

- No applet may import another applet — all cross-applet communication via the event bus
- Each applet depends only on `Core` (the shared Swift Package)
- The Shell (app target) is the composition root — it imports all applets + Core
- Event bus events are generic (`dataCreated(id, type, summary)`) — not typed to specific applet domain models
- Cross-applet data access uses event-driven projections, not shared databases

## Testing & Testability (enforced on every PR)

Testability is a design requirement, not an afterthought. Every change large enough to warrant a PR must satisfy all four rules below.

### 1. Design for testability

- Services and repositories are injected as **protocols**, never concrete types, at applet boundaries.
- Dependencies flow through the composition root or SwiftUI `@Environment` — no static singletons, no hidden globals, no `Date.now` / `UUID()` called directly inside testable logic (inject clocks and ID generators).
- View models are `@Observable @MainActor` and depend only on protocol-typed services.
- Side effects (network, DB, filesystem, HomeKit, Keychain) live behind injectable interfaces so tests substitute fakes or in-memory doubles.
- If a piece of logic cannot be tested without spinning up a real network, real device, or real clock — **redesign it** before merging.

### 2. Ship tests with the change

- **New code paths** → unit tests with mocked dependencies.
- **New GRDB schema or query** → integration test against an in-memory `DatabaseQueue` + `GRDBSnapshotTesting` where schema shape matters.
- **New cross-applet event or tool call** → test that publishes/subscribes through a real in-memory `SuperEventBus`.
- **New or changed SwiftUI view** → **snapshot test required.** Use `pointfreeco/swift-snapshot-testing`. Cover the view's key states (empty, loading, populated, error) and the variants that matter for Super: light + dark mode, at minimum one larger Dynamic Type size, and Reduce Motion where animation is involved. Any applet-level layout (iPhone tab view, iPad/Mac split view) needs a snapshot per form factor. Only rerecord snapshots when the visual change is intentional — never rerecord to "make the test pass."
- **Bug fix** → a regression test that **fails before the fix** and passes after. If you can't write one, explain why in the PR description.
- **No reducing coverage thresholds.** Core ≥80%, applets ≥70%, server ≥80%. Add tests, not exceptions.

### 3. Run the module's tests locally before opening a PR

- **Swift package**: `swift test` from the package root (e.g., `Packages/Chat/`). All tests green before `gh pr create`.
- **TypeScript server**: `pnpm test` (unit + integration) from `super-server/`. All tests green before `gh pr create`.
- If a change crosses multiple packages, run tests in each touched package.
- A PR that couldn't pass its own module's tests locally must not be pushed. CI will catch it, but that wastes the feedback loop.

### 4. PR description must state what was tested

Every PR description includes a **Test Coverage** section naming the new/updated tests and confirming the module's suite passes locally. Example format is in [CI_PIPELINE.md](./docs/CI_PIPELINE.md) §6.2.

### Why this is here and in CI

`CI_PIPELINE.md` defines the blocking checks (test jobs, Codecov thresholds, branch protection). This section is the upstream rule that agents read before acting — it stops untested work from being opened as a PR in the first place, rather than relying on CI to reject it after the fact. Module-level `AGENTS.md` files may add module-specific testing expectations (e.g., "Chat tests must mock `LLMService` and `ToolRouter` — never hit a real LLM provider").

## Sync

- Custom platform-agnostic sync (not CloudKit)
- GRDB/SQLite on client, Postgres on backend
- Change-set protocol over HTTPS

## Third-Party APIs

- Avoid external API integrations unless essential to an applet's core function
- **BYOK (Bring Your Own Key)** — Super is open source; never ship API keys. Users provide their own.
- API key entry is part of applet onboarding — an applet that requires a key prompts for it during setup
- Keys stored in Keychain (client) or encrypted columns (server), never in plaintext

## Backend

- TypeScript + Hono + Drizzle + PostgreSQL + Redis
- Single backend with domain-separated code modules
- Backend proxies all LLM API calls (API keys never on client)

## AGENTS.md Policy

`AGENTS.md` is the canonical agent-instruction file for this project. `CLAUDE.md` is a symlink to `AGENTS.md` so Claude Code picks it up; other agent tools that read `AGENTS.md` directly work without configuration.

This root `AGENTS.md` contains global rules that apply to the entire project. Each module/directory should have its own `AGENTS.md` (with `CLAUDE.md` symlinked alongside it) with rules scoped to that module only. Agents load them hierarchically — a module's `AGENTS.md` adds to (not replaces) the root rules.

When creating a new module:

1. Write `AGENTS.md` in the module root.
2. Create a symlink next to it: `ln -s AGENTS.md CLAUDE.md`.
3. Never edit `CLAUDE.md` directly — it's a symlink. Always edit `AGENTS.md`.

A module `AGENTS.md` should contain:
- What the module does (one-line summary)
- Module-specific conventions or patterns
- Key dependencies and how they're used
- Testing expectations for that module
- Anything an AI agent needs to know to work in that module independently

Keep module `AGENTS.md` files small and focused. Don't repeat rules from this root file.
