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
- `OBSERVABILITY.md` — Apple-built-in posture for crashes, metrics, diagnostics, logs. No third-party SDKs anywhere in this project.
- `SECURITY.md` — threat model, encryption, auth, home automation safety
- `AI_TOOLS.md` — approved AI development tools and security rules
- `CHAT_INTERACTIONS.md` — cross-applet interaction catalog
- `DEVELOPMENT_SETUP.md` — clone, build, deploy, first-run wizard
- `Chat/` — Chat (AI chatbot) applet-specific design and architecture
- `SuperBible/` — SuperBible target docs: `OVERVIEW.md` and `OBSERVABILITY.md`. SuperBible is the public App Store target; SuperOS is the founder's personal app. Both share Core + Chat + Bible.
- `superpowers/specs/2026-05-23-superbible-fork-design.md` — SuperBible fork design (architecture, milestones, monetization, cloud roadmap). Read before touching `App-SuperBible/`, the `SuperBible` target in `project.yml`, or future `Packages/{Plans,Memorize,Quiz,Learn}/`.

## Terminology

- **Applet** = an individual app within Super (Chat, ToDo, Calendar, Home, etc.)
- **Module** = a Swift Package Manager code module (not the same as an applet)
- **Shell** = the Super app container that hosts applets

## Worktree discipline

When invoked inside a git worktree (path looks like `<repo>/.claude/worktrees/<name>/`), **do all file edits there**. The main repo checkout and the worktree share `.git` but have separate working trees; an edit to a file under the main repo path is invisible to the worktree (and vice versa), and the main repo may carry unrelated uncommitted work from another session that your changes would mix into.

- The session env hint (`Primary working directory: …`) is the authoritative workspace root. Treat it as the *only* place file writes are allowed unless the user explicitly says otherwise.
- Prefer relative paths and the shell's current working directory over hardcoded absolute paths. Absolute paths copied from docs, memory, prior agent output, or `git log` typically point at the main repo and will silently land in the wrong tree.
- Before writing the first file in a session, sanity-check: does the absolute path you're about to use start with the worktree root? If not, rewrite it.
- **When dispatching subagents (Explore, Plan, general-purpose) from a worktree, give them the worktree root and require every path they return to be relative to it (or absolute *under* it).** Explore/Plan agents resolve and report absolute paths against the main repo by default, so their output is the single most common source of wrong-tree edits — never paste an agent's absolute path straight into Read/Edit without re-rooting it to the worktree first.
- After a batch of edits, run `git status` from the worktree to confirm your changes appear there — not the main repo. A clean `git status` in the worktree when you expected changes is a red flag that you edited the wrong path.
- If you discover edits landed in the main repo by mistake: `cp` each file from the main repo into the matching worktree path, then `git checkout HEAD -- <files>` and `rm` untracked files in the main repo to restore it. Do **not** stash, commit, or push from the main repo to recover — the main repo may have pre-existing uncommitted work you shouldn't touch.
- A `PreToolUse` hook (`.claude/hooks/block-outside-worktree.sh`, wired in `.claude/settings.json`) backstops all of the above: it denies any Edit/Write/NotebookEdit whose absolute path lands outside the active worktree (`$HOME/.claude/` is exempt for plans/memory). It's a safety net, not a substitute — the relative-path habit and the first-write sanity-check above are still the first line of defense.
- **After the PR merges, clean up.** Once the PR for a worktree's branch is merged to `main` (squash or otherwise — verify with `gh pr view <N> --json state` showing `MERGED`), remove the worktree and delete the local branch. The local branch will be ahead of `main` post-squash, so `-d` refuses — use `-D` (the branch's content lives in the squash commit on `main`, so this is safe). The remote branch is usually auto-deleted by GitHub's "Automatically delete head branches" setting; verify with `git ls-remote --heads origin <branch>` and `git push origin --delete <branch>` if it lingers. Always `cd` to the main repo root before `git worktree remove` — running it from inside the worktree being removed fails silently. Run `git worktree prune` after to clear stale registrations. Skipping this leaves a stack of merged-but-living branches and orphaned worktrees that mask which work is actually in flight.

## Swift function declarations

Follow the Swift book — [Functions chapter](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/functions/) — for anything not stated here. Parameter naming (argument labels, prepositions, `_`) lives in [`docs/NAMING_CONVENTIONS.md` Part 2](./docs/NAMING_CONVENTIONS.md#part-2--function-parameters). The in-tree rules we hold the line on:

- **Defaults last.** Parameters without defaults come first. Use defaults to collapse small overload families into one function.
- **Implicit return.** Single-expression bodies drop `return`: `func nextID() -> String { UUID().uuidString }`.
- **No `-> Void`.** Leave it implicit.
- **Tuples for 2–3 related returns** with named members; reach for a struct beyond that. Optional tuples (`(min: Int, max: Int)?`) when the whole tuple may be absent.
- **Typed errors.** Throwing APIs throw a `Sendable` enum defined alongside the API (see `LLMProviderRegistryError`, `ToolRegistryError`) — not `NSError` or strings. Order keywords as `async throws`.
- **Variadic (`T...`).** The parameter immediately after a variadic must carry an argument label — the compiler requires it to disambiguate calls.
- **`inout` is rare** — prefer returning a new value. The book covers the constraints when you do need it.

## Source-file documentation

Every public protocol, type, enum, struct, class, and free function ships with a short `///` doc comment **placed directly above the declaration** (so Xcode's Quick Help and Swift documentation tools pick it up). Keep it tight — the goal is orientation, not explanation of obvious code.

- **Where**: `///` immediately above the declaration. No multi-paragraph file-header banners — if a file's primary purpose isn't obvious from its single primary type's doc, split it or rename it.
- **Length**: 1–3 sentences. Skip trivial `init`s and property accessors when meaning is obvious from the signature.
- **Functions**: document parameters and return only when non-obvious from the signature, using Swift's `/// - Parameters:` / `/// - Returns:` markup. `func setEnabled(toolID: String, enabled: Bool)` needs none; `func stream(messages:model:tools:temperature:)` with non-obvious `temperature` semantics does.
- **Test files**: `///` on the test suite struct naming what surface is under test. Individual `@Test` cases only need docs when the case name leaves intent unclear.
- **Expand domain acronyms on first use per file** (SSE, LLM, MCP, JWT, GRDB, BYOK, …) so a cold reader doesn't have to grep.
- **Why over what.** Don't restate what the code says — explain non-obvious behavior (a workaround, a perf trick, a deliberate divergence from a doc).

## Naming

All naming — files, folders, function parameters, Swift type suffixes, SwiftUI view buckets, GRDB schema — lives in **[`docs/NAMING_CONVENTIONS.md`](./docs/NAMING_CONVENTIONS.md)**. Read it before coining a new name.

## Typography

All text resolves through `SuperTypography` (`Packages/Core/Sources/Core/Theme/SuperTypography.swift`), read from `@Environment(\.superTypography)`. **Route every `Text` through the `typography.*` accessors** (`display`, `mono`, `font(_:)`, `font(size:)`) — never raw `.font(.system(...))` or `Font.custom(...)`. That keeps the brand-face swap and scale centralized; a literal `.system`/`.custom` call silently opts out of both.

**This is lint-enforced, not just convention.** The `super_typography_only` SwiftLint `custom_rules` rule in [`.swiftlint.yml`](./.swiftlint.yml) fails the build (`error` severity) on any `.font(.system…)`, `.font(.custom…)`, or bare `Font.system` / `Font.custom` in the linted source — App, Core, and Chat. The required `SwiftLint` CI check (`.github/workflows/swiftlint.yml`) gates merge on it. The rule skips comments (so doc-comment mentions of the banned forms are fine), exempts `SuperTypography.swift` itself as the one sanctioned caller, and exempts the test targets (snapshot reference grids are fixtures, not product surfaces). For an SF Symbol or other size that doesn't map to a `Role`, use `typography.font(size:)` (pair it with a `@ScaledMetric` base when the surface should honor OS Dynamic Type); never reach back for `.font(.system(size:))`. Need a genuinely sanctioned raw call outside `SuperTypography.swift`? Add `// swiftlint:disable:next super_typography_only` with a one-line rationale rather than weakening the rule.

Type scales along **two independent axes**, one knob each:

- **App font-scale slider** (`fontScale`, set in Settings) — folded into every accessor's size. This is a **global size control**: it scales *all* app text, reading content and chrome alike. Opt a surface out with **`tracksFontScale: false`**, which renders at the unscaled base size regardless of the slider — now reserved for the handful of fixed brand marks (see below).
- **OS Dynamic Type** (the system text-size / accessibility setting) — carried by `relativeTo:` on a brand face (pass `nil` to ignore it), or by a `@ScaledMetric` base fed to `font(size:)` on a system face (the system path strips `relativeTo`).

Rule of thumb: **everything scales with the slider** (the default, `tracksFontScale: true`) — message content, the sidebar drawer (rows, nav, `CHATS` label, wordmark), and the Bible reader all track it. Chrome that should also honor OS Dynamic Type pairs the default slider tracking with a `@ScaledMetric` base fed to `font(size:)` (see `SidebarDrawer`'s `navLabelSize` / `rowTitleBase` for the canonical dual-axis pattern). The two axes compose.

`tracksFontScale: false` is the **rare** exception, for a brand mark that must stay a fixed visual anchor regardless of the slider — today only the Settings monogram (`SettingsAboutPane`) and the model badge (`SettingsModelsPane`). A **page/sheet title that labels the content you're reading is content** and scales (e.g. `SettingsHeader`'s centered title keeps the default `font(.body)`). Don't reach for `tracksFontScale: false` on anything else — the sidebar's earlier slider-independence was intentionally removed.

Snapshot implication: because almost every surface now tracks the slider, a view's `*_font_scale_max_*` baseline renders at the **scaled** size — re-record it when the view legitimately changes, but never re-record a `fontScale == 1.0` baseline to "make a test pass" (identity at 1.0× means it must stay byte-identical). For the rare `tracksFontScale: false` brand mark, the `*_font_scale_max_*` baseline must still be byte-identical to its `1.0×` render.

## Theming & Controls

Glass and chrome resolve through `SuperGlass` (`Packages/Core/Sources/Core/Theme/SuperGlass.swift`), the single owner of how Super adopts iOS 26 Liquid Glass — the companion to `SuperTypography` (faces) and `SuperTheme` (color). Route every glass surface through its helpers; never call `.glassEffect(...)` directly at a call site (that hard-codes the tint and skips the snapshot solid-fallback).

- **Buttons and controls use interactive glass.** Apply **`superGlassButton(in:)`** to tappable chrome (nav buttons, toolbar controls). It renders `Glass.regular.tint(theme.glassTint).interactive()` so the control reacts to touch, and re-asserts the full `shape` as the `contentShape` (glass otherwise collapses the hit region to the glyph — the bug that broke the hamburger). Drop any pre-existing fill + border + drop-shadow first; glass supplies its own edge and elevation. `SettingsHeader`'s 44pt circular leading button is the canonical control.
- **Passive inline glass surfaces use `superGlassSurface(in:)`** — the frosted `.regular`, non-interactive variant (nav pills, selection pills) so inner segment buttons keep their own taps. Never clear glass over text.

### Sheets

Sheets are **native `.sheet`** (system-presented), never a custom overlay — the system supplies the drag indicator, scrim, and detent behavior. (This is about *presentation*; turning the Chat transcript itself into a sheet was tried and rejected — that decision stands and isn't reopened by this rule.)

- **Consistent nav bar + navigation button.** Every sheet opens with a top chrome bar carrying a leading circular `superGlassButton` (close `✕` at the root, back chevron on pushed sub-panes) and a centered title. `SettingsHeader` is the reference; match its structure (leading button, centered title, hidden trailing spacer to keep the title centered). Multi-pane sheets drive navigation with a `NavigationStack` (see `SettingsSheet`) so pushes get the native left-to-right transition.
- **Background is Super theme color, not glass.** The sheet's content panel fills with the active theme's `background` (or `backgroundRaised`) — a full-bleed glass sheet is too distracting behind reading/editing content. Glass stays on the *controls* (the nav button), not the panel.

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
- **Reactive vs. imperative reads — pick by who mutates the rows.** The deciding question is *not* how a view is built but whether the data on screen can change without that view being the one that changed it:
  - **A view whose on-screen state *is* a database query, and whose rows can be mutated outside that view** (another screen, another applet via the event bus, background work, sync) **must bind reactively** via **[GRDBQuery](https://github.com/groue/GRDBQuery)** — a `@Query` over a `ValueObservation`-backed request that re-renders automatically on any write, wherever it originated. For a pure list-of-records view the `@Query` request *is* the view model: domain filter logic becomes the request's parameters and the view binds straight to the result. Do **not** wrap such a view in an `@Observable` view model with its own `refresh()` — that pull-based projection silently goes stale on outside writes. (Example: ToDo tasks — edited from the list, from detail, from Chat cross-applet.)
  - **A view whose state is owned solely by that view's own flow, or which merges DB rows with in-memory-only state** (in-flight streaming, actor state, unsaved drafts) **may use an `@Observable` view model with imperative repository reads**, refreshed through its domain's own event channel rather than a DB observation. This is correct, not a violation — `@Query` can only project the DB slice and would force a redundant second mechanism. (Example: Chat's transcript — written only by its own `ChatSession`, merged with a non-persisted streaming tail.)
  - Either way, **never hand-roll a `ValueObservation` inside a view model.** Reactive binding goes through GRDBQuery `@Query`; imperative reads go through repositories. There is no third option.
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
- **New or changed SwiftUI view** → **snapshot test required.** Use `pointfreeco/swift-snapshot-testing`. Cover the view's key states (empty, loading, populated, error) across the **light / dark / sepia × default Dynamic Type** matrix at minimum, plus Dynamic Type XXL for any view with text reflow, plus Reduce Motion where animation is involved. Any applet-level layout (iPhone tab view, iPad/Mac split view) needs a snapshot per form factor. Only rerecord snapshots when the visual change is intentional — never rerecord to "make the test pass."
- **Bug fix** → a regression test that **fails before the fix** and passes after. If you can't write one, explain why in the PR description.
- **No reducing coverage thresholds.** Core ≥80%, applets ≥70%, server ≥80%. Add tests, not exceptions.

### 4. Run the module's tests locally before opening a PR

- **Swift package**: `swift test` from the package root (e.g., `Packages/Chat/`). All tests green before `gh pr create`.
- **TypeScript server**: `pnpm test` (unit + integration) from `super-server/`. All tests green before `gh pr create`.
- If a change crosses multiple packages, run tests in each touched package.

### 5. iOS testing: match CI's Xcode + simulator runtime + iPhone

Snapshot baselines are pixel-exact comparisons. A baseline recorded on one Xcode + iOS simulator runtime + iPhone model will fail on another, even between **point builds of the same iOS minor** (e.g. `26.4.0` vs `26.4.1`), because the system text renderer and SwiftUI layout passes change. **Always record against CI's runtime.** Today that is **Xcode 26.4.1 + iOS 26.4.1 (build `23E254a`) simulator on iPhone 17** running on the `macos-26` runner image; verify with `xcodebuild -version` and `xcrun simctl list runtimes iOS` (the 26.4 runtime must be build `23E254a`) before recording.

- **Xcode**: pinned literally to `26.4.1` (not `latest-stable`) by `maxim-lobanov/setup-xcode@v1` in every workflow under `.github/workflows/`. Match the version locally — install via `xcodes install 26.4.1` and select with `xcode-select -s /Applications/Xcode.app` (or `DEVELOPER_DIR=...` per-command when multiple Xcodes are installed). The `xcodebuild -version` build number in the worktree and on a fresh CI log must agree. Do **not** repin to Xcode 26.5 until it ships GA on the runner image — it's currently beta on macos-26, and pinning to a beta means re-recording baselines again when GA arrives.
- **iOS simulator runtime**: CI pins the **exact build `23E254a`** (iOS 26.4.1) — the build `macos-26` bundles with Xcode 26.4.1. The `Pick iOS simulator` step in `ios-build.yml` asserts `buildversion == 23E254a` (there must be exactly one iOS 26.4.x runtime, and it must be that build) and fails the leg loudly otherwise. **Local hazard:** `26.4.0` (`23E244`) and `26.4.1` (`23E254a`) both report as "iOS 26.4", and simctl conflates them under one identifier (`iOS-26-4`) with no per-device build field — so a `-destination` with `OS=26.4` can silently land on the wrong build. Keep **only** `23E254a` installed locally: list with `xcrun simctl runtime list`, delete a stale `23E244` with `xcrun simctl runtime delete <uuid>`. The `.claude/hooks/enforce-snapshot-sim.py` PreToolUse guard refuses concrete-sim `xcodebuild` runs while any other 26.4.x build is installed, so this can't be forgotten. If `23E254a` ever stops being installable, the same fallbacks apply:
  1. Drop the affected per-test variant with a one-line rationale in the PR description. The default snapshot matrix (`light/dark/sepia × default Dynamic Type`) usually survives cross-runtime drift; Dynamic Type XXL and other accessibility-large variants are the ones most likely to fail and are the candidates for deferral.
  2. For sub-pixel drift only (anti-aliasing on a custom font, not structural layout shifts), use the `precision`/`perceptualPrecision` tolerance pattern from `verifyEmpty` in `ChatScreenSnapshotTests` — only acceptable when a real regression would still register at the chosen tolerance. A perceptual delta above ~5% is structural, not anti-aliasing, and tolerance is not the right tool.
- **iPhone model**: CI's `Pick iOS simulator` step looks up `iPhone 17` on `iOS 26.4` by name + runtime. Pin it the same way locally for the recording command (`-destination "platform=iOS Simulator,name=iPhone 17,OS=26.4"`) — note `OS=26.4` names the minor only; the build is guaranteed by keeping just `23E254a` installed (see the runtime bullet above). Do **not** rely on simctl's default device-list order — it's not stable across machines, which is why we stopped using "first iPhone on highest runtime".

Before recording new snapshot baselines, confirm the local Xcode + runtime + device match CI's resolved trio. If they can't match exactly, document the gap and the chosen mitigation (e.g., perceptual tolerance, deferred variant) in the PR description.

### 6. PR description must state what was tested

Every PR description includes a **Test Coverage** section naming the new/updated tests and confirming the module's suite passes locally. Example format is in [CI_PIPELINE.md](./docs/CI_PIPELINE.md) §6.2.

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
- Backend proxies all LLM API calls (API keys never on client) — **applies to SuperOS only.** SuperBible is serverless (local-only v1, CloudKit-private planned for v2) and issues BYOK calls directly from device to provider; see [`App-SuperBible/AGENTS.md`](./App-SuperBible/AGENTS.md) for the SuperBible rule.

## AGENTS.md Policy

`AGENTS.md` is the canonical agent-instruction file; `CLAUDE.md` is a symlink to it so Claude Code picks it up alongside tools that read `AGENTS.md` directly. Module rules load hierarchically — a module's `AGENTS.md` *adds to* the root, never replaces it.

When creating a new module: write `AGENTS.md` in the module root, then `ln -s AGENTS.md CLAUDE.md`. Never edit `CLAUDE.md` directly.

**Keep module `AGENTS.md` files small. Don't repeat rules from this root file** — point back to it instead. The module file is for what's unique: module-specific patterns, gotchas, and testing expectations beyond the root.
