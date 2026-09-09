# Bible Navigation History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add offline chapter history capped at 25 entries, with back/forward buttons inside the book/translation selector.

**Architecture:** A pure history value belongs to `BibleScreenViewModel`. A versioned payload on the existing GRDB reading-position row stores the entire history and cursor atomically with current chapter/translation. Existing navigation sources funnel through explicit visit versus traversal paths.

**Tech Stack:** Swift, SwiftUI, Observation, GRDB, Swift Testing, existing Argos visual capture tools.

**Spec:** [Bible navigation history design](../specs/2026-09-08-BIBLE_NAVIGATION_HISTORY_DESIGN.md).

**Status:** Production implementation authorized after native prototype approval. Fresh plan review completed; the pre-load and retry-race findings below are incorporated. Implementation and local QA are complete; PR delivery and CI review remain.

## Global constraints

- At most **25 chapter visits, including the current visit**.
- Translation remains the current reader preference on back/forward; same-chapter navigation preserves forward history.
- Persist in `bible.sqlite`; no network, cloud sync, new package, or cross-applet database access.
- Use `SuperTypography`, `SuperGlass`, theme tokens, and compact 32 × 44 pt history hit areas.
- Read root and Bible `AGENTS.md`, `docs/TESTING.md`, and `docs/VISUAL_TESTING_POLICY.md` before implementation.
- All edits stay in `/Users/bwang/.codex/worktrees/170c/Super` unless the user authorizes another workspace.

## Task 1: Pure chapter-history model

**Files:** Modify `Packages/Bible/Sources/Bible/Models/BiblePosition.swift`; create `Models/BibleNavigationHistory.swift` and `Tests/BibleTests/Models/BibleNavigationHistoryTests.swift` under the Bible package.

**Interface:** `BibleNavigationHistory: Codable, Sendable, Equatable`, initialized with `init(initialPosition: BiblePosition)`. Read-only `entries`, `currentIndex`, `current`, `canGoBack`, `canGoForward`; static `capacity = 25`; mutating `visit(_:)`, `goBack()`, `goForward()`. The operations return `Bool` indicating change. Add Codable to `BiblePosition`.

- [x] Write tests for the invariant and branching first. Concrete core regression:

```swift
let a = BiblePosition(bookId: "1PE", chapterNumber: 2)
let b = BiblePosition(bookId: "JHN", chapterNumber: 3)
let c = BiblePosition(bookId: "PSA", chapterNumber: 23)
let d = BiblePosition(bookId: "ROM", chapterNumber: 8)
var history = BibleNavigationHistory(initialPosition: a)
#expect(history.visit(b))
#expect(history.visit(c))
#expect(history.goBack())
#expect(history.current == b)
#expect(history.canGoForward)
#expect(history.visit(d))
#expect(history.entries == [a, b, d])
#expect(!history.canGoForward)
```

- [x] Run `swift test --filter BibleNavigationHistoryTests` from `Packages/Bible`; confirm the new API is missing before implementing.
- [x] Implement visit by returning early on equality, removing entries after the cursor, appending, trimming excess from the front, and setting the cursor to `entries.count - 1`. Traversal only increments/decrements a valid cursor. Keep mutation private to these methods.
- [x] Cover 26 distinct Psalm chapters → entries 2…26, current index 24; back and forward at bounds; `[A,B,A]` retained; same-current selection after back preserves C; after backing from C to B, explicitly visiting C appends a fresh C without duplication. Test Codable equality and reject invalid decoded indices before exposing `current`.
- [x] Rerun the focused suite, then commit the model and its tests.

## Task 2: Atomic persistence and migration

**Files:** Modify `Database/BibleDatabase.swift`, `Models/BibleReadingPositionRecord.swift`, and `Repositories/GRDBBibleReadingPositionRepository.swift` only if explicit coding needs require it. Extend `Tests/BibleTests/Repositories/BibleReadingPositionRepositoryTests.swift`, `Database/BibleDatabaseTests.swift`, `Database/BibleSchemaSnapshotTests.swift`, and its existing text schema snapshot. Create `Models/BibleNavigationHistoryPayload.swift` for the versioned encoding/recovery boundary.

**Interface:** `BibleNavigationHistoryPayload` encodes version 1. Define `static func encode(_ history: BibleNavigationHistory) throws -> String` and `static func restore(from json: String?, position: BiblePosition, catalog: BibleBookCatalog) -> BibleNavigationHistory`. `restore` validates the envelope and returns a single-position history on invalid input; caller supplies an already catalog-validated fallback position. Persisted record gains `navigationHistoryJSON: String? = nil` in its initializer. Repository `load`/`save` signatures remain unchanged.

- [x] Add round-trip and legacy migration tests before the new column. Build a release-shaped migrator with `registerBibleMigrations`, migrate to `v12_narrationPrefetch`, insert an existing reading row, then apply all migrations and confirm its chapter/translation and unrelated rows survive.
- [x] Append explicit SQL migration `ALTER TABLE bibleReadingPosition ADD COLUMN navigationHistoryJSON TEXT;` under the next available migration ID; do not edit earlier migrations.
- [x] Encode one payload and save it on the existing row together with the pointed-to chapter. Use a nullable string so malformed nested JSON cannot make GRDB fail to decode the otherwise usable reading-position record.
- [x] Test missing JSON, malformed JSON, unknown version, empty/oversize arrays, invalid book/chapter, out-of-bounds cursor, and cursor/row disagreement. Each recovers to the supplied valid position with no forward history.
- [x] Verify atomic whole-record replacement and a temporary on-disk database close/reopen with `[A,B,C]` at B. Confirm both back and forward availability survive and B remains current.
- [x] Run `swift test --filter BibleReadingPositionRepositoryTests` and `swift test --filter BibleDatabaseTests` from `Packages/Bible`; update and verify the text-only schema snapshot using its existing test strategy. Commit schema, record, payload, and tests.

## Task 3: Reader navigation and restoration

**Files:** Modify `ViewModels/BibleScreenViewModel.swift` and `UI/BibleScreen.swift`; create `Tests/BibleTests/ViewModels/BibleScreenViewModelHistoryTests.swift` and a gated reading-position repository helper under `Tests/BibleTests/Helpers/` if an existing helper cannot gate load/save.

**Interface:** Expose `canGoBack`, `canGoForward`, `backDestination: BiblePosition?`, `forwardDestination: BiblePosition?`, `goBack()`, `goForward()`, and `isRestoringNavigation`. Add `flushNavigationPersistence() async` for the background lifecycle hook. Keep the existing chapter and reference APIs unchanged for callers.

- [x] Write the source-route regression using `BundledBibleTextLoader`, an in-memory GRDB reading repository, `FixedClock`, and `FakeNarrationService`:

```swift
await model.load() // default 1 Peter 2
model.selectChapter(bookId: "JHN", chapterNumber: 3)
model.openReference(bookId: "PSA", chapterNumber: 23, verseStart: 1, verseEnd: 2)
model.goBack()
#expect(model.position == BiblePosition(bookId: "JHN", chapterNumber: 3))
#expect(model.canGoForward)
model.selectTranslation(.web)
#expect(model.canGoForward)
model.stepChapter(.next)
#expect(model.position == BiblePosition(bookId: "JHN", chapterNumber: 4))
#expect(!model.canGoForward)
await model._waitForPendingPersist()
```

- [x] Add explicit navigation intent internally (visit versus traverse); funnel validated `stepChapter`, `selectChapter`, and cross-chapter `openReference` into that transition. Keep existing same-chapter verse-selection and scroll behavior after the history no-op.
- [x] On history traversal, stop narration; clear verse selection, pending scroll, and chapter-bound sheets; reset immersive/footer state; load target text; save cursor without appending. Retain current translation.
- [x] Make `load()` idempotent and share the first restore operation. Queue reference/translation intents from initialization, including before the first `load()` call. A retry is also single-flight and gates incoming intents until its read completes, then drains them in arrival order. Gate chapter/history/translation controls while restoring; queue incoming reference and programmatic translation intents and drain in arrival order after restoration. Flush must await restoration. A repeated `.task` or applet appearance must never reload over live navigation.
- [x] Distinguish absent row, successfully read row with invalid history, and thrown read errors. Seed/repair only the first two. A read failure enables temporary session reading but suppresses writes to the existing disk record; add a retry action to the transient error UI. On successful retry, restore disk history, append only the currently displayed resolved chapter if provisional navigation occurred, apply the latest explicitly chosen translation, and save the complete resulting state. Intermediate temporary visits are omitted during recovery. Do not replay relative steps/traversals against recovered history. Test `A→B→C→Back→D` and retry immediately after Back: visible D/B respectively must be preserved, with no provisional C resurrected. Nil repository remains a session-only mode.
- [x] Extend the existing immutable record capture and ordered `persistTask` chain with the history payload. Fresh/legacy/recovered successful loads persist a valid initial history. Handle write errors visibly through existing transient UI, retaining session state; the next navigation and background flush retry the latest complete snapshot. Hook `flushNavigationPersistence()` into `BibleScreen` background lifecycle using `scenePhase`.
- [x] Test mixed rapid visits/traversal/translation writes, initial-load references, translation and flush during gated load, read failure then successful retry (assert no intervening disk overwrite), repeated loads, invalid inputs, unavailable text, selection/narration cleanup, save failure then successful retry, and nil repository session history. Use gated continuations and `_waitForPendingPersist()`, never timing sleeps. Confirm a fresh model restores the final cursor and forward entries.
- [x] Run `swift test --filter BibleScreenViewModel` from `Packages/Bible`; fix affected existing fixtures and commit the reader integration.

## Task 4: Selector controls and adaptive layout

**Files:** Modify `UI/BibleNavBar.swift`, `UI/BibleScreen.swift`, and `UI/BibleChapterReader.swift`. Create `UI/BibleNavigationSelector.swift` to isolate the grouped controls. Keep the approved full-label then wrapping fallback; no new abbreviation table. Extend `UI/Snapshots/BibleNavBarSnapshotTests.swift`, existing reader snapshots, and `Scripts/VisualTesting/package-inventory.json` when captures are added.

**Interface:** Add distinct history inputs/callbacks (`canGoBack`, `canGoForward`, destination labels, `onGoBack`, `onGoForward`) to the nav bar. Existing `canStep*` and `onPrevious`/`onNext` continue to mean biblical chapter stepping. The selector owns only presentation and callbacks, with no database reads.

- [x] Build the requested order: back, forward, divider, book, existing divider, translation. Each chevron gets a separate 32 × 44 pt hit target, disabled semantics, destination hint, and selection haptic style. Use one `SuperGlass` surface and `SuperTypography` fonts.
- [x] Use a 64 pt history pair with glyphs 28 pt center-to-center by offsetting each glyph 2 pt toward the pair's center within its 32 × 44 pt target. This trims 12 pt from each outer margin of the prior native prototype. Apply the offset to the image only; keep button frames/content shapes adjacent and non-overlapping. Check taps on both glyphs and near their shared boundary, including a disabled neighbor.
- [x] Implement width fitting: full label, then a full-width selector row under utility controls. In the expanded SuperOS layout, put biblical chapter stepping in the utility row so the selector keeps the full available width. Grow/wrap at accessibility sizes and use a two-line rounded surface if needed. Preserve full VoiceOver citations and prevent hit-area overlap with shell hamburger/action buttons.
- [x] Measure the resulting nav-bar height and pass a top content reserve into `BibleChapterReader`, replacing its fixed 68 pt padding. Compute the immersive hide distance from measured height plus safe-area clearance, replacing `BibleScreen`'s fixed 120 pt offset. Preserve current single-row spacing and avoid double-counting safe areas. Verify the long-name/large-type chapter heading remains visible and the entire toolbar hides on scroll.
- [x] Preserve existing host chapter arrows and selection-pill behavior. Confirm SuperOS's larger cluster uses the fallback cleanly, while SuperBible's composer chapter controls remain independent.
- [x] Reuse current light/dark, selection, narration, and font-scale captures. Add one bounded history-state gallery (first-only, oldest, middle, newest) and one compact-width/long-name accessibility case only if the existing suite cannot expose those defects. Proposed maximum inventory addition: **2 images**; from the current 623 to 625 total (Bible 276 to 278). Recount at implementation time and report actual delta/rationale; no generated PNGs in Git.
- [x] Validate independent taps, accessibility labels/disabled states, and boundary hit regions on the worktree simulator. Commit the selector and fixtures after targeted visual verification. Hardware keyboard and VoiceOver gesture traversal are not automated by the available simulator tooling; report that limitation.

## Task 5: Complete QA and delivery

- [x] Run the whole Bible package suite with `swift test` from `Packages/Bible`: 873 tests across 86 suites passed.
- [x] Match `Scripts/VisualTesting/simulator-pins.json`; use `python3 Scripts/worktree_simulator.py ensure` and its returned UUID. Generate schemes and run Bible simulator tests with parallel testing disabled. For image capture use `python3 Scripts/VisualTesting/capture.py Bible --output .build/bible-history-visual-capture` from the repository root, with a fresh output directory.
- [x] Build both `Super` and `SuperBible` against that simulator because the shared nav bar affects both hosts. Follow the exact commands in `docs/TESTING.md`.
- [x] Manually visit A→B→C, back to B, relaunch from the local database, forward to C, back to B, then open D. Verify C disappears, D survives relaunch, translation remains current, and native controls fit long names and accessibility sizes. Verify no interaction goes to the adjacent biblical chapter accidentally.
- [x] Have a separate review subagent review production changes; address serious actionable findings and rerun affected checks.
- [ ] Create a draft PR using the repository template, with local results and capture-count rationale. Follow root `AGENTS.md` for CI/Codex review, current-revision approval, ready/auto-merge, and eventual merge verification. Monitor at the specified 10-minute cadence using a scheduled wakeup.

## Validation record

- `swift test` from `Packages/Bible`: 873 tests in 86 suites passed, including a fresh rerun after replacing a forced try in a new test helper with error propagation.
- Pinned iPhone 17 / iOS 26.4.1 (23E254a), Xcode 26.4.1 (17E202): 874 nonvisual simulator tests passed; both Super and SuperBible builds passed.
- Full Bible visual driver: 278 images validated across 26 serialized suites. Inventory grows by 2 to 625 total: history-state gallery and narrow long-name accessibility layout. Existing nav-bar canvases grow to 160 pt and toast fixtures become 260 pt galleries to include the new content without extra image fanout.
- Changed-file SwiftLint: no errors. Existing view-model warnings and the JSONEncoder UTF-8 conversion warning remain. Diff checks passed. Visual pipeline tests: 19 passed.
- Native SuperBible smoke: `[1 Peter 2, John 3, Psalms 23]` at John survived relaunch with forward history; Forward opened Psalms, then an edge tap on Back returned to John. Selecting KJV preserved Forward. Opening Romans 8 removed Psalms, and relaunch restored Romans/KJV. Read-only SQLite inspection confirmed one matching row/payload/cursor.
- Native large-text Song of Solomon layout kept the heading below the expanded toolbar; scrolling removed the full toolbar. Normal text size was restored. Accessibility labels, destinations, disabled states, and independent tap regions were inspected; hardware keyboard/VoiceOver gesture traversal and network-disconnected-device testing were not performed.
- Storage and final whole-branch reviews passed. UI review identified restoration gating for composer actions and a toast hit-area regression; both were fixed and passed re-review. The final whole-branch reviewer found no serious actionable production issues.
- Generated visual images remain ignored/local; Argos is the baseline store.

## Production plan review

Fresh subagent review identified two required tests: intents received before the first load, and intents received during a suspended restoration retry. The restore gate starts at initialization; both initial load and retries are single-flight. Queued absolute reference and translation intents drain after restoration. Retain the approved full-label/wrapping fallback, with no compact-citation formatter. Main was refreshed to dac76b09; the new migration is v13_navigationHistory, with a v12 upgrade fixture.
