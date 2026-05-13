# Super — Agent Guidelines

## Documentation

All design documents live in `docs/`. Read the relevant docs before working on any component:

- `PRODUCT_VISION.md` — overall vision, applet breakdown, principles
- `DESIGN.md` — app shell, applet manager, navigation layouts
- `NAMING_CONVENTIONS.md` — files & folders, function parameters, Swift type taxonomy, SwiftUI views, GRDB schema (the single rulebook for *anything name-shaped*)
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

## Worktree discipline

When invoked inside a git worktree (path looks like `<repo>/.claude/worktrees/<name>/`), **do all file edits there**. The main repo checkout and the worktree share `.git` but have separate working trees; an edit to a file under the main repo path is invisible to the worktree (and vice versa), and the main repo may carry unrelated uncommitted work from another session that your changes would mix into.

- The session env hint (`Primary working directory: …`) is the authoritative workspace root. Treat it as the *only* place file writes are allowed unless the user explicitly says otherwise.
- Prefer relative paths and the shell's current working directory over hardcoded absolute paths. Absolute paths copied from docs, memory, prior agent output, or `git log` typically point at the main repo and will silently land in the wrong tree.
- Before writing the first file in a session, sanity-check: does the absolute path you're about to use start with the worktree root? If not, rewrite it.
- After a batch of edits, run `git status` from the worktree to confirm your changes appear there — not the main repo. A clean `git status` in the worktree when you expected changes is a red flag that you edited the wrong path.
- If you discover edits landed in the main repo by mistake: `cp` each file from the main repo into the matching worktree path, then `git checkout HEAD -- <files>` and `rm` untracked files in the main repo to restore it. Do **not** stash, commit, or push from the main repo to recover — the main repo may have pre-existing uncommitted work you shouldn't touch.

## Swift function declarations

Follow the official guidance in [The Swift Programming Language — Functions](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/functions/). The rules below are the ones we hold the line on; the linked chapter is the source of truth for anything not stated here.

> **Naming parameters** (argument labels, omitting labels with `_`, preferring prepositions): see [`docs/NAMING_CONVENTIONS.md` Part 2 — Function parameters](./docs/NAMING_CONVENTIONS.md#part-2--function-parameters). The rules below cover function *shape*, not parameter naming.

### Default parameter values

- Place parameters without defaults first, before parameters with defaults. The Swift book justifies this directly: parameters without defaults are usually more important to the function's meaning, so writing them first makes it easier to recognize the same function across call sites with different optional arguments.
- Use defaults to collapse small overload families into a single function rather than declaring multiple overloads.

### Variadic parameters

- Reach for `T...` when zero-or-more values is the natural shape (e.g. `print(_ items: Any...)`).
- A function may declare multiple variadic parameters, but the parameter immediately after a variadic parameter must have an argument label so the compiler can disambiguate the call.

### In-out parameters

- Reserve `inout` for the rare case where you genuinely need to mutate a caller-owned variable (the swap pattern). Returning a new value is almost always cleaner.
- `inout` parameters can't have default values and can't be variadic. Pass them with `&` at the call site.

### Return values

- Single-expression function bodies should rely on implicit return — drop the `return` keyword. Example: `func nextID() -> String { UUID().uuidString }`.
- Use tuple return types (with named members) when a function naturally returns two or three closely-related values; reach for a struct beyond that.
- Don't add `-> Void` — leave it implicit. Functions without a `->` clause already return `Void` (the empty tuple `()`).
- Use optional tuples (`(min: Int, max: Int)?`) when the *whole tuple* may legitimately be absent.
- A function declared with a return type *must* return on every path — the compiler enforces this, and so should code review.

### Throwing functions

- Mark functions that may throw with `throws`; mark async-throwing functions with `async throws` (in that order).
- Throw a typed error (a `Sendable` enum) defined alongside the throwing API rather than `NSError` or string literals. See `LLMProviderRegistryError` and `ToolRegistryError` for the in-tree pattern.

## Source-file documentation

Every public protocol, type, enum, struct, class, and free function ships with a short `///` doc comment **placed directly above the declaration** (so Xcode's Quick Help and Swift documentation tools pick it up). Keep it tight — the goal is orientation, not explanation of obvious code.

- **Where the docs go**: `///` immediately above the declaration. Do **not** write a multi-paragraph file-header banner — if a file's primary purpose isn't obvious from its single primary type's doc, split it or rename it.
- **Length**: 1–3 sentences per declaration. Skip docs on trivial `init`s and property accessors when meaning is obvious from the signature.
- **Functions**: document parameters, return value, and usage **only when not obvious** from the signature. Use Swift's `/// - Parameters:` / `/// - Parameter name:` / `/// - Returns:` markup so Xcode Quick Help renders them. A `func setEnabled(toolID: String, enabled: Bool)` doesn't need parameter docs; a `func stream(messages:model:tools:temperature:)` with non-obvious semantics for `temperature` does. Single-param functions whose param is described by the type usually don't need parameter docs at all.
- **Test files**: `///` on the test suite struct naming what surface is under test (e.g., "Tests for `SSEParser`'s framing across chunk boundaries."). Individual `@Test` cases don't need docs unless the case name leaves intent unclear.
- **Expand domain acronyms on first use within each file** so a cold reader doesn't have to grep. Examples: SSE = Server-Sent Events, LLM = Large Language Model, MCP = Model Context Protocol, JWT = JSON Web Token, GRDB = Swift SQLite library, BYOK = Bring Your Own Key, JSON, HTTP, URL, UUID. After the first expansion the acronym alone is fine.
- **Don't restate what the code says.** Prefer "Buffers partial chunks until a frame boundary appears." over "Appends data to the buffer and parses events."
- **Why over what.** When behavior is non-obvious (a workaround, a perf trick, a deliberate divergence from a doc), say *why*.

This rule complements the root system prompt's general guidance — it does not override the rule against overly chatty inline comments inside function bodies. Keep `//` inline comments rare; reserve prose for the `///` doc comments above declarations where a reader actually looks for orientation.

## Naming

All naming guidance — files, folders, function parameters, Swift type suffixes, SwiftUI view buckets, GRDB schema — lives in **[`docs/NAMING_CONVENTIONS.md`](./docs/NAMING_CONVENTIONS.md)**. Read it before coining a new file name, type name, or schema name. Quick map:

- **Files and folders** (markdown, Swift, TypeScript, doc subdirectories) — [Part 1](./docs/NAMING_CONVENTIONS.md#part-1--files-and-folders).
- **Function parameters** (argument labels) — [Part 2](./docs/NAMING_CONVENTIONS.md#part-2--function-parameters).
- **Swift types** — architectural-layer suffixes (`*Session`, `*Store`, `*Registry`, `*Repository`, `*Provider`, `*Driver`, `*Assembler`, `*Generator`, `*Estimator`, `*Tool`, `*Record`, `*Event`, `*Command`, `*Error`), anti-patterns, decision tree — [Part 3](./docs/NAMING_CONVENTIONS.md#part-3--swift-types-architectural-layer).
- **SwiftUI views** (Chat applet — Screen / Drawer / Sheet / Pane / Region / Pill / Banner / Bubble / Block / Row / …) — [Part 4](./docs/NAMING_CONVENTIONS.md#part-4--swiftui-view-layer-chat-applet).
- **GRDB schema** (table, column, foreign-key, timestamp, index naming) — [Part 5](./docs/NAMING_CONVENTIONS.md#part-5--persistence-schema).

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

- **[GRDB](https://github.com/groue/GRDB.swift)** (not SwiftData/Core Data) for all persistence
- All data models are `struct` conforming to `Codable, FetchableRecord, PersistableRecord, Sendable`
- Each applet gets its own `.sqlite` file via `DatabaseQueue`
- Use `DatabaseMigrator` with explicit SQL for schema migrations
- Use **[GRDBQuery](https://github.com/groue/GRDBQuery)** for reactive SwiftUI data binding — views subscribe via `@Query` to a `ValueObservation`-backed request and re-render automatically when the database changes. This is the only sanctioned bridge between GRDB and SwiftUI; do not hand-roll observation in view models.
- Use **[GRDBSnapshotTesting](https://github.com/groue/GRDBSnapshotTesting)** for snapshot testing of database state

### GRDB schema naming

See [`docs/NAMING_CONVENTIONS.md` Part 5 — Persistence schema](./docs/NAMING_CONVENTIONS.md#part-5--persistence-schema) for table, column, foreign-key, timestamp, and index naming. Server-side Postgres (Drizzle) uses `snake_case` and is covered in the same section.

## Architecture Rules

- No applet may import another applet — all cross-applet communication via the event bus
- Each applet depends only on `Core` (the shared Swift Package)
- The Shell (app target) is the composition root — it imports all applets + Core
- Event bus events are generic (`dataCreated(id, type, summary)`) — not typed to specific applet domain models
- Cross-applet data access uses event-driven projections, not shared databases

## Testing & Testability (enforced on every PR)

Testability is a design requirement, not an afterthought. Every change large enough to warrant a PR must satisfy all five rules below.

### 1. Design for testability

- Services and repositories are injected as **protocols**, never concrete types, at applet boundaries.
- Dependencies flow through the composition root or SwiftUI `@Environment` — no static singletons, no hidden globals, no `Date.now` / `UUID()` called directly inside testable logic (inject clocks and ID generators).
- View models are `@Observable @MainActor` and depend only on protocol-typed services.
- Side effects (network, DB, filesystem, HomeKit, Keychain) live behind injectable interfaces so tests substitute fakes or in-memory doubles.
- If a piece of logic cannot be tested without spinning up a real network, real device, or real clock — **redesign it** before merging.

### 2. Make async tests deterministic

Async tests establish ordering through `await`, not through hope. Most "flaky" tests aren't bugs in the code under test — they're races in the test fixture itself. The fixes are usually small once the race is named; the cost is the hours spent chasing a 1-in-N flake to find it.

- **Synchronize on conditions, not time.** `Task.yield()` polling loops and `Task.sleep` waits are race amplifiers, not synchronization primitives. Await an observable signal: a continuation, an awaitable handle on the work itself, or the work's own result. If you can't express "the spawned work is done" as a single `await`, expose a test seam on the production type that returns a handle — see `ChatScreenViewModel._waitForPendingTitleTask()` for the in-tree pattern (underscore prefix marks it as test-only surface, not stable API).
- **Drain spawned work *before* asserting, not after.** A fire-and-forget `Task { ... }` inside a method that returns synchronously is invisible to the caller — the test has to drain it explicitly via the test seam, and the drain must come *before* the assertions read observable state. Otherwise assertions snapshot a value the task may still mutate, and tests fall back to polling helpers (`yieldUntilHeaderUpdates`, `yieldUntilFiredCount`) that mask races without closing them.
- **Sequence asymmetric parallel work explicitly.** When `async let` blocks share a fixture (a mock script queue, a counter, a registry) and the spawned work has *different shapes* (one path triggers a tool loop, the other doesn't), the order in which they consume the fixture matters. Establish the order with an `await` on an observable signal *between* the spawns — not after both have already fanned out. Use the side effect of the first work item (a tool's `awaitFirstCall()`, an actor's "I started" continuation) as the synchronization point.
- **Prefer strict test doubles.** A mock that `fatalError`s on misuse — empty queue, unexpected method, wrong argument — attributes the bug to its caller, where the stack trace is useful. A lenient default lets test misconfigurations hide until a *different* test fails later for non-obvious reasons. The in-tree `FakeLLMProvider` is strict by design and that's load-bearing.
- **`.serialized` is a smell, not a fix.** Reaching for `@Suite(.serialized)` (or its XCTest equivalent) means there's a race somewhere — between tests, or between a test's own spawned work and its assertions. Serialization narrows the race window without closing it, and lets the actual bug live longer. Find the race and fix the synchronization; the suite stays parallel.

### 3. Ship tests with the change

- **New code paths** → unit tests with mocked dependencies.
- **New GRDB schema or query** → integration test against an in-memory `DatabaseQueue` + `GRDBSnapshotTesting` where schema shape matters.
- **New cross-applet event or tool call** → test that publishes/subscribes through a real in-memory `SuperEventBus`.
- **New or changed SwiftUI view** → **snapshot test required.** Use `pointfreeco/swift-snapshot-testing`. Cover the view's key states (empty, loading, populated, error) and the variants that matter for Super: light + dark mode, at minimum one larger Dynamic Type size, and Reduce Motion where animation is involved. Any applet-level layout (iPhone tab view, iPad/Mac split view) needs a snapshot per form factor. Only rerecord snapshots when the visual change is intentional — never rerecord to "make the test pass."
- **Bug fix** → a regression test that **fails before the fix** and passes after. If you can't write one, explain why in the PR description.
- **No reducing coverage thresholds.** Core ≥80%, applets ≥70%, server ≥80%. Add tests, not exceptions.

### 4. Run the module's tests locally before opening a PR

- **Swift package**: `swift test` from the package root (e.g., `Packages/Chat/`). All tests green before `gh pr create`.
- **TypeScript server**: `pnpm test` (unit + integration) from `super-server/`. All tests green before `gh pr create`.
- If a change crosses multiple packages, run tests in each touched package.
- A PR that couldn't pass its own module's tests locally must not be pushed. CI will catch it, but that wastes the feedback loop.

### 5. PR description must state what was tested

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
