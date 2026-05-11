# Swift Naming Conventions

The single rulebook for naming Swift types in this repo. Two scopes:

1. **Architectural layer** — orchestration, Core, persistence. Suffixes
   that govern what a type *is* (an actor that owns state, a protocol
   that crosses a persistence boundary, a struct that projects data).
2. **SwiftUI view layer** — currently scoped to the Chat applet, since
   it's the only applet shipped. Names that govern what a *view* is
   (a Screen, a Drawer, a Pill, a Banner).

`*ViewModel` sits at the seam between the two — listed in the SwiftUI
section because that's where view models are constructed and consumed.

## Why this matters

A consistent suffix tells the reader at a glance what shape they're
dealing with: "this is the persistence boundary," "this owns runtime
state," "this is a pure projection," "this is a screen-level view." When
the same suffix means different things in different folders, every reader
has to open the file before they know what they're looking at — and AI
agents end up reverse-engineering conventions from existing types every
time. Pinning the meanings here keeps both costs low.

The cross-cutting policy this doc builds on lives in
[`AGENTS.md` §Swift Concurrency & Type
Policy](../AGENTS.md#swift-concurrency--type-policy): structs for data,
actors for shared mutable state, `@Observable @MainActor final class` for
view models, `final class` + `os_unfair_lock` for synchronous atomic
access. The suffixes below are how we *name* the things that follow that
policy.

## Table of contents

**Part 1 — Architectural layer**

1. [`*Session`](#session) — long-lived per-unit orchestrator
2. [`*Store`](#store) — in-memory keyed pool of live runtime instances
3. [`*Registry`](#registry) — container for registered, swappable components
4. [`*Repository`](#repository) — persistence boundary for one record type
5. [`*Provider`](#provider) — abstraction over an external resource
6. [`*Driver`](#driver) — protocol-fitting adapter at a layer seam
7. [`*Assembler`](#assembler) — pure projection between shapes
8. [`*Generator`](#generator) — factory for one value
9. [`*Estimator`](#estimator) — pure calculation function
10. [`*Tool`](#tool) — discrete LLM-invokable capability
11. [`*Record`](#record) — GRDB persistable row
12. [`*Event`](#event) — Sendable stream/bus value
13. [`*Command`](#command) — parsed user intent
14. [`*Error`](#error) — typed subsystem error
15. [Verb-noun (no suffix)](#verb-noun-no-suffix) — single-purpose worker
16. [`Live*` / `Fake*` / `InMemory*` / `Mock*` / `Noop*` / `Placeholder*` prefixes](#prefixes)
17. [Anti-patterns](#anti-patterns)
18. [Decision tree](#decision-tree)

**Part 2 — SwiftUI view layer (Chat applet)**

19. [Rule 0 — drop the `View` suffix](#ui-rule-0)
20. [Rule 1 — pick a bucket, use its suffix](#ui-rule-1)
21. [Rule 2 — one struct per file](#ui-rule-2)
22. [Rule 3 — data passed to a view ≠ the view](#ui-rule-3)
23. [Rule 4 — view models](#ui-rule-4)
24. [Invariants (grep checks)](#ui-invariants)

Companion to Part 2: [`docs/Chat/UI_STRUCTURE.md`](./Chat/UI_STRUCTURE.md)
— what view owns what, organized by surface. That's the org chart; this
doc is the rulebook.

---

# Part 1 — Architectural layer

<a id="session"></a>

## `*Session`

**Pattern.** Long-lived orchestrator that owns the runtime state and turn
loop for **one logical unit of work** (one conversation, one user, one
in-flight RPC).

- **Kind:** `actor` (always).
- **State:** owns the unit's in-flight state (`currentTask`, policy
  flags, accumulated buffers).
- **Concurrency:** actor-isolated. Each session serializes its own work
  on its actor executor; sibling sessions run independently.
- **Lifetime:** outlives the view model that started it. Re-attachment
  is by id, via a [`*Store`](#store).

**In-tree examples:**
- `ChatSession` — one per conversation; owns the user-message → LLM → tool
  → loop cycle. `Packages/Chat/Sources/Chat/Orchestration/ChatSession.swift`.

**Do not use `*Session` for:** a short-lived one-shot operation (that's a
*Generator* or just a free function), an internal helper class with no
public lifetime (that's an implementation detail of its owner), or
something that holds many units (that's a *Store* or *Registry*).

---

<a id="store"></a>

## `*Store`

**Pattern.** In-memory **keyed pool of live runtime instances**.
Typically multiplexes a `*Session` per key (one per conversation, one per
user). Returns the same instance on repeated lookups for the same key.

- **Kind:** `actor` (always — the map is shared mutable state).
- **State:** `[Key: T]` plus any cross-key bookkeeping.
- **Concurrency:** actor-isolated.
- **API shape:** typically `func get(for key:)` (get-or-create),
  `func shutdown()`, `func runningKeys()`.

**In-tree examples:**
- `ChatSessionStore` — `[conversationId: ChatSession]`.
  `Packages/Chat/Sources/Chat/Orchestration/ChatSessionStore.swift`.

**Do not use `*Store` for:**
- A persistence boundary to a database — that's a [`*Repository`](#repository).
- A protocol whose only impl talks to GRDB — same thing, that's a
  *Repository* regardless of what its in-memory test double is called.
- A typed facade over a key-value settings table — name it for what it
  does (e.g. `*Settings`, `*Reader`, or fold into the underlying
  Repository).
- A registry of pluggable components — that's a [`*Registry`](#registry).

> **History.** Until early 2026 we had `ToolEnablementStore` (a
> persistence protocol) and `ChatSessionStore` (a live-actor map) sharing
> the suffix. The former was renamed to `ToolEnablementRepository` so the
> suffix means one thing.

---

<a id="registry"></a>

## `*Registry`

**Pattern.** Container for **registered, swappable components**. The
distinguishing API is `register(_:)` / `unregister(_:)` plus
identity-bearing lookups; components present a contract (a `*Provider`,
a `*Tool`).

- **Kind:** `actor` (always).
- **State:** `[ID: Registration]` plus optional "which is active" pointer.
- **Concurrency:** actor-isolated.

**In-tree examples:**
- `LLMProviderRegistry` — holds `[id: any LLMProvider]` plus an active
  pointer. `Packages/Core/Sources/Core/LLM/LLMProviderRegistry.swift`.
- `ToolRegistry` — holds `[toolID: ToolRegistration]`; hydrates each
  registration's enabled flag from a `ToolEnablementRepository`.
  `Packages/Core/Sources/Core/Tools/ToolRegistry.swift`.

**Do not use `*Registry` for:**
- A lazy-on-demand creator (no `register` call) — that's a [`*Store`](#store).
- A persistence boundary — that's a [`*Repository`](#repository).

---

<a id="repository"></a>

## `*Repository`

**Pattern.** Persistence boundary for **one record type**. Always a
`protocol` with one or more `struct` conformers — the protocol shape
hides GRDB from the rest of the world.

- **Kind:** `protocol` + `struct` impl(s).
- **State:** none in the protocol; the GRDB impl wraps a `DatabaseQueue`.
- **Concurrency:** `Sendable`. Methods are `async throws`.
- **API shape:** `fetchAll(...)`, `fetch(id:)`, `save(_:)`, plus
  record-specific queries. **Never caches** — that's the caller's job.

**In-tree examples:**
- `MessageRepository` / `GRDBMessageRepository`.
- `ToolCallRepository` / `GRDBToolCallRepository`.
- `ConversationRepository` / `GRDBConversationRepository`.
- `CompactionCheckpointRepository` / `GRDBCompactionCheckpointRepository`.
- `ModelConfigurationRepository` / `GRDBModelConfigurationRepository`.
- `SettingRepository` / `GRDBSettingRepository`.
- `ToolEnablementRepository` (Core) / `GRDBToolEnablementRepository`
  (Chat) + `InMemoryToolEnablementRepository` (Core tests).

**Naming details:**
- Protocol lives where its primary consumer lives. For most records that's
  the same package as the record (consumer = applet, record = applet, GRDB
  conformer = applet). When the consumer is Core — which stays GRDB-free —
  the protocol lives in Core while the record + GRDB conformer stay in the
  applet that owns the database. `ToolEnablementRepository` is the
  canonical cross-package example: protocol in Core (because `ToolRegistry`
  consumes it), `ToolEnablementRecord` + `GRDBToolEnablementRepository` in
  Chat (because Chat owns `chat.sqlite`).
- GRDB conformer name is `GRDB` + the protocol name. `MessageRepository`
  → `GRDBMessageRepository`; `ToolEnablementRepository` →
  `GRDBToolEnablementRepository`.
- Test double name is `InMemory` + the protocol name (e.g.
  `InMemoryToolEnablementRepository`), per the existing pattern in
  `Packages/Core/Tests/CoreTests/Helpers/`.

**Do not use `*Repository` for:**
- An in-memory keyed pool of live actors — that's a [`*Store`](#store).
- A protocol that returns *behavior* rather than *records* — that's a
  [`*Provider`](#provider).

---

<a id="provider"></a>

## `*Provider`

**Pattern.** Abstraction over **an external resource** — an API, a
network service, a model backend. Protocol + one or more concrete impls
named for the resource.

- **Kind:** `protocol` + `struct` impl (when stateless) or `actor` (when
  the impl holds state — e.g. a connection pool).
- **State:** typically none.
- **Concurrency:** `Sendable`.

**In-tree examples:**
- `LLMProvider` / `OpenAICompatibleLLMProvider`.
  `Packages/Chat/Sources/Chat/LLM/OpenAICompatibleLLMProvider.swift`
  conforms to `Core.LLMProvider`.

**Do not use `*Provider` for:**
- A persistence boundary — that's a [`*Repository`](#repository).
- A layer-seam adapter — that's a [`*Driver`](#driver).

---

<a id="driver"></a>

## `*Driver`

**Pattern.** Protocol-fitting **adapter at a layer seam**. A `*Driver`
relays calls from one layer's API onto the underlying implementation —
threading default arguments the inner type expects but the outer protocol
hides, or adding cross-cutting behavior (lazy save, retry,
instrumentation) without leaking that into the inner type.

- **Kind:** `protocol` + multiple `struct`/`actor` impls per cross-cutting
  variant.
- **State:** none, or one decoration's worth (e.g. a "have we ensured
  saved?" flag).
- **Concurrency:** `Sendable`. Inner type's actor isolation is whatever
  the inner type chose.

**In-tree examples:**
- `ChatSessionDriver` — protocol the view model depends on. Hides
  `ChatSession`'s temperature default and lets tests substitute a fake.
  `Packages/Chat/Sources/Chat/ViewModels/ChatScreenViewModel.swift`.
- `LiveChatSessionDriver` — production adapter wrapping a `ChatSession`.
  `Packages/Chat/Sources/Chat/ViewModels/ChatSessionDriver+Adapter.swift`.
- `LazyConversationDriver` — App-layer decorator that ensures the
  conversation row is saved before the first turn.
  `App/LazyConversationDriver.swift`.

**Do not use `*Driver` for:**
- An external-resource abstraction — that's a [`*Provider`](#provider).
- An LLM-invokable capability — that's a [`*Tool`](#tool).

---

<a id="assembler"></a>

## `*Assembler`

**Pattern.** Pure **projection between shapes**. Takes a snapshot of one
representation and returns a different one. The return value pair is
typically `*Assembler` → `*Assembly`.

- **Kind:** `struct` (`Sendable`).
- **State:** none (may inject collaborators like `TokenEstimator`).
- **Concurrency:** stateless; runs on the caller's actor.

**In-tree examples:**
- `ContextAssembler` → `ContextAssembly`. Projects persisted records into
  the `[LLMMessage]` shipped to a provider; folds in the live compaction
  checkpoint.
  `Packages/Chat/Sources/Chat/Orchestration/ContextAssembler.swift`.

**Do not use `*Assembler` for:**
- A factory of a single value — that's a [`*Generator`](#generator).
- A worker that does I/O — that's a verb-noun ([`Compactor`-style](#verb-noun-no-suffix)).

---

<a id="generator"></a>

## `*Generator`

**Pattern.** Factory for **one value**. May be pure (id generation) or
thin-I/O (LLM-backed title generation); the distinguishing trait is that
each call returns one fresh value.

- **Kind:** `protocol` (when test seam matters) or `struct` (one-off).
- **State:** none in production; test doubles may hold a counter.
- **Concurrency:** `Sendable`.

**In-tree examples:**
- `IDGenerator` / `UUIDGenerator` / `DeterministicIDGenerator`.
  `Packages/Core/Sources/Core/Ambient/IDGenerator.swift`.
- `TitleGenerator` — runs a one-shot LLM call from the first user/
  assistant exchange.
  `Packages/Chat/Sources/Chat/Orchestration/TitleGenerator.swift`.

**Do not use `*Generator` for:**
- A projection (no new value, just a reshape) — that's an [`*Assembler`](#assembler).
- A calculation (a number) — that's an [`*Estimator`](#estimator).

---

<a id="estimator"></a>

## `*Estimator`

**Pattern.** Pure **calculation function** producing a numeric estimate
(cost, size, budget).

- **Kind:** `protocol` + `struct` impl.
- **State:** none.
- **Concurrency:** `Sendable`; deterministic.

**In-tree examples:**
- `TokenEstimator` / `HeuristicTokenEstimator` (chars/4 heuristic).
  `Packages/Chat/Sources/Chat/Orchestration/TokenEstimator.swift`.

**Do not use `*Estimator` for:**
- A value factory — that's a [`*Generator`](#generator).
- Anything that does I/O — estimators must be cheap to call on the hot
  path.

---

<a id="tool"></a>

## `*Tool`

**Pattern.** Discrete capability the **LLM can invoke** via a tool call.
A `*Tool` registers itself into a `ToolRegistry` via a `ToolRegistration`
and exposes both metadata (for the LLM) and an executor.

- **Kind:** `struct` factory exposing `static func registration() -> ToolRegistration`.
- **State:** per-tool; the executor inside the registration may be a `struct`
  or `actor`.
- **Concurrency:** `Sendable`.

**In-tree examples:**
- `TimeNowTool` — returns the current wall clock + timezone.
  `Packages/Chat/Sources/Chat/Tools/TimeNowTool.swift`.

**Do not use `*Tool` for:**
- A capability not exposed to the LLM — that's a regular method on a
  service-layer type.

---

<a id="record"></a>

## `*Record`

**Pattern.** GRDB persistable row.

- **Kind:** `struct` conforming to `Codable, FetchableRecord, PersistableRecord, Sendable`.
- **State:** the row's columns; primary key `id` (String UUID), timestamps
  in `camelCase`.
- **Concurrency:** `Sendable` value type.

**In-tree examples:** every `Packages/Chat/Sources/Chat/Models/*.swift` —
`MessageRecord`, `ToolCallRecord`, `ConversationRecord`,
`CompactionCheckpointRecord`, `ModelConfigurationRecord`,
`ToolEnablementRecord`, `SettingRecord`.

See [`AGENTS.md` §Persistence](../AGENTS.md#persistence) and §GRDB Naming
Conventions for full column/index naming rules.

---

<a id="event"></a>

## `*Event`

**Pattern.** Sendable value emitted on an `AsyncStream` or event bus.

- **Kind:** `enum` (`Sendable, Equatable`) with one case per kind of
  thing-that-happened.
- **State:** none (cases may carry associated values).
- **Concurrency:** `Sendable` value.

**In-tree examples:**
- `ChatEvent` — emitted by `ChatSession`'s `AsyncStream`.
  `Packages/Chat/Sources/Chat/Orchestration/ChatEvent.swift`.
- `LLMStreamEvent` — emitted by `LLMProvider.stream(...)`.
  `Packages/Core/Sources/Core/LLM/LLMStreamEvent.swift`.

---

<a id="command"></a>

## `*Command`

**Pattern.** Parsed user intent dispatched from a composer or CLI.

- **Kind:** `enum` (`Sendable, Equatable`) with a parser
  (`init?(rawText:)`).
- **State:** none (cases carry associated values).
- **Concurrency:** `Sendable` value.

**In-tree examples:**
- `SlashCommand` — `/compact` today.
  `Packages/Chat/Sources/Chat/Orchestration/SlashCommand.swift`.

---

<a id="error"></a>

## `*Error`

**Pattern.** Typed `Error` for one subsystem. Per
[`AGENTS.md` §Throwing functions](../AGENTS.md#throwing-functions): every
throwing API throws a typed error defined alongside it.

- **Kind:** `enum: Error, Sendable, Equatable`.
- **State:** none (cases carry associated values).

**In-tree examples:**
- `CompactorError`, `LLMError`, `LLMProviderRegistryError`,
  `ToolRegistryError`, `VoiceInputError`.

---

<a id="verb-noun-no-suffix"></a>

## Verb-noun (no suffix)

**Pattern.** Single-purpose **worker** named for what it does. Use when
the operation has a strong verb form ("compact a conversation," "reduce
an SSE stream") and no existing suffix above fits cleanly.

- **Kind:** `actor` (when it owns state or does I/O) or `struct` (when
  pure).
- **State:** per case.

**In-tree examples:**
- `Compactor` (`actor`) — runs a summarization turn; writes a checkpoint.
  `Packages/Chat/Sources/Chat/Orchestration/Compactor.swift`.
- `OpenAIStreamReducer` (`struct`) — folds raw SSE chunks into typed
  events. `Packages/Chat/Sources/Chat/LLM/OpenAIStreamReducer.swift`.

**Do not use verb-noun for:** anything where a suffix above applies
cleanly. Reach for this only when the suffix taxonomy genuinely doesn't
have a fit.

---

<a id="prefixes"></a>

## `Live*` / `Fake*` / `InMemory*` / `Mock*` / `Noop*` / `Placeholder*` prefixes

When a protocol has multiple impls, prefix the impl name with its
intent so call sites read clearly.

- **`Live*`** — production implementation. Used when the protocol has
  enough non-production conformers that "the production one" is worth
  distinguishing by name. Example: `LiveChatSessionDriver`.
- **`InMemory*`** — implementation backed by in-process state instead of
  a database/network. Common for test doubles, but **not test-only** —
  ship in `Packages/Core/Tests/...Helpers/` or alongside production
  protocols. Example: `InMemoryToolEnablementRepository`.
- **`Fake*`** — strict test double that `fatalError`s on misuse. Marks
  test misconfiguration loudly. Example: `FakeLLMProvider` in
  `Packages/Chat/Tests/ChatTests/Orchestration/Helpers/FakeLLMProvider.swift`.
- **`Mock*`** — invocation-recording test double (records calls, returns
  scripted results). Example: `MockToolExecutor` in
  `Packages/Core/Tests/CoreTests/Helpers/MockToolExecutor.swift`.
- **`Noop*`** — minimal no-op conformer used to satisfy a protocol
  dependency the test under test doesn't exercise. Test-only. Example:
  `NoopEnablementRepository` in sidebar VM tests.
- **`Placeholder*`** — production-shipped conformer that *deliberately
  lies* in a controlled way to keep dependents compiling/rendering when
  the real subsystem isn't wired (e.g., previews). Example:
  `PlaceholderVoiceInputService` — claims `isAvailable` but returns
  `.denied` from `requestPermissions()`.

---

<a id="anti-patterns"></a>

## Anti-patterns

- **`*Manager` or `*Coordinator` or `*Helper` or `*Utility`** — too vague.
  Pick the suffix above that names what the type actually does.
- **`*Service`** — currently load-bearing only at the UI seam
  (`VoiceInputService` paired with `VoiceInputController`); there is no
  general-purpose `*Service` pattern in the architectural layer. Do not
  introduce new `*Service` types in orchestration or Core; reach for
  [`*Provider`](#provider) (external-resource boundary),
  [`*Driver`](#driver) (layer-seam adapter), or
  [`*Repository`](#repository) (persistence) instead. The
  `*Controller`/`*Service` UI pair is documented in
  [Part 2 Rule 4](#ui-rule-4) and the broader writeup is forthcoming.
- **Mismatched protocol/impl pairs** — if the protocol is
  `XRepository`, the GRDB impl is `GRDBXRepository`, not
  `XStore` / `XAdapter` / `XService`. The pair must read as one thing.
- **Renaming "the same shape" type to match its file location** — if you
  catch yourself writing `Repositories/FooStore.swift`, that's a code
  smell: the suffix should match the folder's role, not the variable
  name you almost typed.

---

<a id="decision-tree"></a>

## Decision tree

Working through the right suffix for a new architectural type:

1. **Does it own state that mutates across calls?**
   - If yes and it's one logical unit → [`*Session`](#session).
   - If yes and it holds many of them by key → [`*Store`](#store) (live
     instances) or [`*Registry`](#registry) (registered components).
   - If yes and it's UI state → [`*ViewModel`](#ui-rule-4) (Part 2).
2. **Is it a boundary to a backing store or external service?**
   - Database → [`*Repository`](#repository).
   - API / model backend → [`*Provider`](#provider).
3. **Does it transform one shape into another?**
   - Records → prompt shape → [`*Assembler`](#assembler).
   - Produces one new value → [`*Generator`](#generator).
   - Produces a number → [`*Estimator`](#estimator).
4. **Is it a value type emitted on a stream/bus?**
   - Stream payload → [`*Event`](#event).
   - User intent → [`*Command`](#command).
   - Error → [`*Error`](#error).
5. **Is it an LLM-invokable capability?** → [`*Tool`](#tool).
6. **Is it a layer-seam adapter (wraps a protocol you don't own)?** →
   [`*Driver`](#driver).
7. **Single-purpose worker that doesn't match above?** → verb-noun
   (`Compactor`, `Reducer`).
8. **A SwiftUI view, view-shape data, or view model?** → see
   [Part 2](#part-2--swiftui-view-layer-chat-applet).

If none of those fit, that's a signal — bring the case to a PR review
before coining a new suffix family, and update this doc at the same time.

---

<a id="part-2--swiftui-view-layer-chat-applet"></a>

# Part 2 — SwiftUI view layer (Chat applet)

The taxonomy an agent or developer applies when naming a new SwiftUI view
in the Chat applet. Pick the bucket; the suffix follows. If nothing fits,
treat that as a smell and stop to add a new bucket here before coining a
one-off name.

The org chart — *what view owns what, surface by surface* — lives in
[`docs/Chat/UI_STRUCTURE.md`](./Chat/UI_STRUCTURE.md). This part is the
rulebook.

<a id="ui-rule-0"></a>

## Rule 0 — drop the `View` suffix

Apple's standard-library views (`Text`, `Button`, `VStack`) are bare nouns; ours should be too. Apply `View` only when the bare name collides with a model/protocol — and if you hit that, rename the model instead. A view's `View`-ness is already declared by `: View` on the struct.

<a id="ui-rule-1"></a>

## Rule 1 — pick a bucket, use its suffix

Every new SwiftUI view fits into one of these buckets. The bucket determines the suffix.

| Bucket | Suffix | What it is | Existing examples |
|---|---|---|---|
| **Screen** | `*Screen` | Full-viewport top-level surface owned by the host. Has a `*ScreenViewModel` — except for trivial bootstrap chrome (e.g. `LoadingScreen`, `FailureScreen`) where the state machine lives in the host. | `ChatScreen`, `LoadingScreen`, `FailureScreen` |
| **Drawer** | `*Drawer` | Edge-anchored overlay that slides in from a side. Paints its own scrim. | `SidebarDrawer` |
| **Sheet** | `*Sheet` | Bottom-anchored modal overlay with rounded top corners. | `SettingsSheet` |
| **Pane** | `*Pane` | Sub-screen content navigated *within* a Sheet/Screen via `NavigationStack`. | `SettingsRootPane`, `SettingsModelsPane`, … |
| **Region** | bare | Composed strip inside a Screen/Pane. Name *is* the role. Regions can nest (a region inside another region or inside a non-Screen view). | `ChatHeader`, `ChatComposer`, `ChatComposerFooter`, `StreamingTail` |
| **Pill** | `*Pill` | Small inline rounded control, often a dropdown trigger. | `ModelPill`, `VerbosityPill` |
| **Meter** | `*Meter` | Progress/measurement indicator. | `ContextMeter` |
| **Row** | `*Row` | One item in a vertical list. | `SettingsRow`, `ChatRow` |
| **Bubble** | `*Bubble` | Chat-bubble-shaped message container. | `UserBubble` |
| **Block** | `*Block` | Collapsible bordered card with header + body. | `ThinkingBlock`, `ToolCallBlock`, `CodeBlock` |
| **Banner** | `*Banner` | Full-width status strip. | `ErrorBanner`, `CompactionBanner` |
| **Group** | `*Group` | Rounded card grouping rows. | `SettingsGroup` |
| **Toggle** | `*Toggle` | Labeled switch. | `SettingsToggle` |
| **Button** | `*Button` | Custom-shaped button (when system `Button` isn't enough). | `MessageActionButton` |
| **Icon** | `*Icon` | Atomic glyph. | `TodoIcon`, `SettingsIcon`, `ModelsIcon`, `CloseIcon` |
| **Primitive** | bare | Single-purpose visual atom that doesn't fit a shape suffix. | `TypingCaret`, `WaitingSpark`, `SpinnerRing` |
| **Style** | `*Style` | `ButtonStyle` / `LabelStyle` / `ProgressViewStyle` conformer. | `SidebarPressableRowStyle` |
| **Modifier** | `*Modifier` | `ViewModifier` conformer. | `HiddenNavigationBarModifier` |

<a id="ui-rule-2"></a>

## Rule 2 — one struct per file (with one carve-out)

Each top-level view, region, component, and primitive lives in its own file named after the struct. The carve-out: a parent file may keep `private` helper structs *only* if (a) they have no callers outside the file and (b) they're <40 lines. The bucket suffix (Row, Block, Style, …) still applies to the helper; the carve-out is only about *where* it lives, not what it's named. `SidebarDrawer.swift` keeps `ChatRow` (private Row, ~34 lines, renders the per-conversation row only inside the drawer), `SpinnerRing` (Primitive), and `SidebarPressableRowStyle` (Style) under that rule.

<a id="ui-rule-3"></a>

## Rule 3 — data passed to a view ≠ the view

When a view needs a state struct/enum as input, name the data by *role* (`*State`, `*Item`, `*Config`), never by *shape*. The view owns `Banner`; the data is `BannerState`. The in-tree examples: `MessageList.StreamingState` is the data; `StreamingTail` is the view. `MessageList.ErrorState` is the data; `ErrorBanner` is the view. `MessageList.Item` and `MessageList.ToolCallItem` carry the projected row payloads consumed by `MessageList` itself.

<a id="ui-rule-4"></a>

## Rule 4 — view models

`@Observable @MainActor final class *ViewModel`. Backing a Screen → `*ScreenViewModel`. Backing a Drawer/Sheet/Pane → `*ViewModel` (no shape suffix on the VM; the VM doesn't know which shape will render it).

> `*Controller` + `*Service` — used today only at the
> `VoiceInputController` + `VoiceInputService` seam (and analogous
> `CodeBlockCopyController`). The `*Controller` is a
> `@MainActor @Observable` state machine that drives a UI subsystem's
> lifecycle; the `*Service` is its injected protocol-boundary collaborator.
> A dedicated writeup of when to reach for this pair (rather than folding
> the state into a `*ViewModel`) is still pending.

<a id="ui-invariants"></a>

## Invariants (grep checks)

After applying this part of the taxonomy, the following greps must return zero hits over `Packages/Chat/Sources/`:

- `rg '\bstruct \w+View\s*:'` — no `View`-suffixed view structs
- `rg '\bstruct \w+Glyph\s*:'` — no `Glyph`-suffixed icon views; the generic `StrokedGlyph<S: Shape>` rendering wrapper is the one intentional exception.
