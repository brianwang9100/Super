# Chat Verse Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Use separate subagents for plan and final implementation review. Steps use checkbox syntax for tracking.

**Goal:** Open chat Bible citations in a temporary chapter modal with editable verse selection and an explicit Open in Bible handoff.

**Architecture:** Separate `.previewRecord` from `.openRecord`, with applet-owned opaque preview content presented by the shared shell. Compose the preview and full reader from shared chapter/study views, using isolated reading models and an applet-lifetime annotation dispatcher.

**Tech Stack:** Swift 6, SwiftUI native sheets, Observation, GRDBQuery, SuperEventBus, Swift Testing, VisualTestSupport/repository PNG baselines.

**Spec:** [Chat verse preview design](../specs/CHAT_VERSE_PREVIEW_DESIGN.md)

## Global constraints

- Workspace: `/Users/bwang/.codex/worktrees/3773/Super`; edit only this worktree.
- No applet-to-applet imports; shared shell imports Core/Chat and opaque MiniApplet values.
- No new persistent tables, third-party packages or resolved versions, provider APIs, or cross-applet imports. Core explicitly declares MarkdownUI's already-resolved swift-cmark dependency to remove internal links through its parsed syntax tree.
- Temporary chapter/selection state; explicit highlight/note/bookmark edits remain persistent.
- Native `.sheet`, existing `SheetNavBar`, `SuperTypography`, and `SuperGlass` only.
- Decorations stay GRDBQuery `@Query` with a chapter-specific reader identity.
- Xcode 26.4.1 (`17E202`), iOS 26.4.1 (`23E254a`), iPhone 17; confirm live pins before QA.
- New public declarations/test suites have short documentation; async tests use completion seams, never sleeps/polling.
- Preserve existing capture coverage; reviewed repository PNGs are the baseline; commit intentional images after explicit recording and comparison.

## Task 1: Share annotation dispatch without sharing reader state

**Files:**
- Create `Packages/Bible/Sources/Bible/ViewModels/BibleAnnotationDispatchViewModel.swift`.
- Modify `Packages/Bible/Sources/Bible/ViewModels/BibleScreenViewModel.swift` and `Packages/Bible/Sources/Bible/Applet/BibleApplet.swift`.
- Test `Packages/Bible/Tests/BibleTests/ViewModels/BibleAnnotationDispatchViewModelTests.swift` and existing dispatch/disclaimer tests.

**Interfaces:** `@Observable @MainActor final class BibleAnnotationDispatchViewModel`; `attach(to: SuperEventBus) async`; `status(for: BibleAnnotationTargetSpec) -> BibleAnnotationDispatchStatus?`; `request(reference: RecordReference, for: BibleAnnotationTargetSpec) -> BibleAnnotationDispatchResult`; `clearFailure(for:)`. `BibleAnnotationDispatchResult` has `.started(requestId: String)`, `.alreadyRunning(requestId: String)`, and `.unavailable`. Only `.started` publishes. The local reader presents the target for the first two outcomes and retains the existing bus-less fallback for `.unavailable`.

- [x] Add real-bus tests: two models share one running request; duplicate request publishes once; matching completion updates both; stale completion cannot clear a retry; preview model release does not lose running/failure state. Subscribe before publishing and drain explicit processed-event seams.
- [x] Run `swift test --package-path Packages/Bible --filter BibleAnnotationDispatchViewModelTests`; new coverage should initially fail for the missing dispatch type.
- [x] Move only bus request/status ownership into the shared model. Preserve full-reader forwarding APIs and test drain seams; keep disclaimer queues, selection, presented sheets, and text construction on each reader model. Attach once in `BibleApplet.attach(to:)`.
- [x] Run new tests and `BibleScreenViewModelDispatchTests`, `BibleScreenViewModelAnnotationsTests`, and `BibleScreenViewModelSidebarTests`. Confirm existing narration attachment and sidebar dismissal still work.
- [x] Commit the tested extraction.

## Task 2: Make chapter content and study presentation reusable

**Files:**
- Create `Packages/Bible/Sources/Bible/UI/BibleChapterNavigation.swift`, `BibleChapterReaderLayout.swift`, `BibleChapterContent.swift`, and `BibleStudySheetsModifier.swift`.
- Modify `Packages/Bible/Sources/Bible/UI/BibleChapterReader.swift`, `BibleScreen.swift`, and `BibleBottomOverlayKind.swift` where ownership comments change.
- Extend `Packages/Bible/Tests/BibleTests/UI/BibleChapterReaderTests.swift`, existing reader snapshots and selection/sheet behavioral tests.

**Interfaces:** `BibleChapterNavigation` contains previous/next labels and callbacks; `BibleChapterReaderLayout` has `topInset` and `bottomInset` with static full-reader/preview presets. `BibleChapterContent` takes the model, layout, optional navigation, overlay kind, study callbacks, and full-reader scroll/footer callbacks. `BibleStudySheetsModifier` takes the model, annotation repository, optional full-reader narration-sheet content, a Bible-link policy, an add-to-chat callback, and a host-completion callback.

- [x] Capture existing full-reader expectations before moving code: selection survives action close, empty selection closes actions, selection-to-note/annotation waits for dismissal, narration replaces action content, and footer visibility still hides composer arrows.
- [x] Change `BibleChapterReader` to render `BibleChapterFooter` only when navigation exists. Replace hardcoded layout clearances with the layout input and preserve the existing overlay reserve and pending-scroll consumption behavior.
- [x] Extract the common content binding and study-sheet presentation from `BibleScreen`. Keep book/translation pickers, narration lifecycle, immersive behavior, shell chrome, and composer accessories owned by the screen. Route book-picker handoffs into the shared study presentation without duplicate sheet presenters.
- [x] Make replacement handoffs explicit and identity-guarded: action tiles capture targets, clear selection/dismiss actions, and run the queued transition from `onDismiss`. Glyph-driven note/annotation presentation preserves selection. Bookmarks keep their existing clear-selection behavior and action-dismissal handoff (retain `presentClearsSelection`). Add narration → note/bookmark → close coverage proving playback and transport return, without expecting bookmark selection retention. Expose an asynchronous finish path that dismisses study sheets before completing the host. Do not use timer delays or attach a second selection sheet to the same host.
- [x] Add behavioral tests for absent navigation and full-reader layout parity. Reuse existing `BibleScreenSnapshotTests` and `BibleChapterReaderTests` to verify the refactor; do not add captures solely for extracted wrappers.
- [x] Run affected Bible tests and relevant simulator reader/action/narration fixtures; commit only once existing behavior remains intact.

## Task 3: Build the isolated chapter preview and generic applet capability

**Files:**
- Create `Packages/Core/Sources/Core/Applet/RecordPreviewCompletion.swift`.
- Modify `Packages/Core/Sources/Core/Applet/MiniApplet.swift`.
- Create `Packages/Bible/Sources/Bible/UI/BibleChapterPreviewSheet.swift`.
- Create `Packages/Bible/Sources/Bible/UI/BiblePreviewPresentationObserver.swift`, a small UIKit readiness adapter under `#if canImport(UIKit)`; macOS compile fallback must not claim an iOS transition occurred.
- Create `Packages/Bible/Sources/Bible/Models/BibleReaderReference.swift` and modify `Packages/Bible/Sources/Bible/Applet/BibleReferenceInbox.swift`.
- Modify `Packages/Bible/Sources/Bible/Applet/BibleApplet.swift` and `ViewModels/BibleScreenViewModel.swift`.
- Modify `Packages/Core/Sources/Core/UI/Markdown/MarkdownText.swift` and `BibleReferenceLinkifier.swift`; add `MarkdownBibleCitationPolicy.swift` there for an environment policy with `.enabled` default and `.plainText` opt-in.
- Modify `Packages/Bible/Sources/Bible/UI/AnnotationSheetContainer.swift`, `AnnotationSheet.swift`, `AnnotationBlock.swift`, and `BibleMarkdownRendering.swift` as needed to carry that policy through the actual annotation renderer.
- Add `Packages/Bible/Tests/BibleTests/Applet/BibleChapterPreviewTests.swift` and `Models/BibleReaderReferenceTests.swift`; extend reader/reference tests and Core's existing `MarkdownText`/linkifier tests.

**Interfaces:** Core's `RecordPreviewCompletion` and `MiniApplet.recordPreview(for:onFinish:)` match the spec. Add `initialTranslation: BibleTranslation = .defaultTranslation` to the existing view-model initializer. The applet constructs a fresh model with `positionRepository: nil`, the captured active translation, shared repositories/dispatch, and the requested initial position. `BibleReaderReference` is an immutable `Sendable, Equatable` Bible-owned value with `position`, `translation`, `selectedVerses`, `recordReference`, and `init?(reference:)`; its versioned grammar is in the spec. Add a full-reader entry `openReference(_ reference: BibleReaderReference)` that validates/loads the chapter, intersects the exact selection with loaded verse numbers, scrolls its minimum, and persists the resulting position once. Existing URL entry points remain supported.

- [x] Add tests with injected text, storage, clock, IDs, clipboard, and haptics. Opening/cancelling must leave the original model and reading-position repository unchanged; selection/highlight/note edits target only the preview chapter; unavailable text never opens actions.
- [x] Cover single/range/chapter links, partial/fully out-of-range verse spans, very large bounds, re-opened identical references, and exact current-selection handoff (contiguous, disjoint, empty) with captured translation. Round-trip `BibleReaderReference`; reject unknown versions, translation IDs, books, invalid chapters, malformed lists, and nonpositive verses. Filter actual loaded verse numbers against range bounds rather than constructing an unbounded `Set(start...end)`. Keep attachment and public URL grammars unchanged.
- [x] Implement the nil-default generic capability and its Bible implementation. Retain/share dependencies inside BibleApplet rather than opening new databases or using hidden globals. Create content/model once per accepted request and inject the same read-only DatabaseContext.
- [x] Resolve the full reader's initial saved state once during `BibleApplet.attach(to:)`, before inbox subscription and shell readiness; make `load()` idempotent and coalesce concurrent callers onto the same awaited restoration task. An initialization/navigation generation guard must prevent an in-flight restore from overwriting explicit chapter/translation navigation. Test a cold launch with a non-Bible backdrop and saved nondefault translation, explicit handoff before first BibleScreen mount, repeated/concurrent load, and gated restore versus navigation. Initialization must never persist a new reading position.
- [x] Build the preview header, selection controls, shared chapter content, and shared study sheets. Fix the chapter/translation; omit all navigation/narration contributions. Gate initial actions with a one-shot `BiblePreviewPresentationObserver` native completion callback, checking the request ID and cancellation state. Do not equate SwiftUI `.task`/`.onAppear` with presentation completion. Preserve pending verse scrolling until the reader consumes it.
- [x] Implement Core's scoped `.plainText` citation rendering: bypass automatic linkification and unwrap explicit Bible-scheme links to their label nodes (including reference-style syntax), preserving formatting, code, and external URLs. Carry the policy through the annotation sheet/container/block chain and retain default enabled behavior elsewhere. Test automatic references, inline/reference-style internal links, mixed external/internal links, code, and default Chat/full-Bible rendering. Retain defensive custom-scheme rejection in BibleMarkdownRendering. Verify disabled citations lack VoiceOver link traits; do not implement this as a no-op tap handler.
- [x] Validate action close/reopen, last-verse scrolling, secondary note/annotation/bookmark sheets, and finish callbacks. Ensure dispatched generation and accepted writes survive dismissal while queued presentation work does not.
- [x] Run Core/Bible tests affected by the capability and model changes; commit the tested preview.

Codec regression to add with the new type (its initializer takes the three
stored fields named above):

```swift
@Test func readerHandoffPreservesDisjointSelectionAndTranslation() throws {
    let target = BibleReaderReference(
        position: BiblePosition(bookId: "ROM", chapterNumber: 8),
        translation: .defaultTranslation,
        selectedVerses: [28, 30]
    )
    let decoded = try #require(BibleReaderReference(reference: target.recordReference))
    #expect(decoded == target)
    #expect(decoded.selectedVerses == [28, 30])
}
```

## Task 4: Route Chat requests through the native shell presenter

**Files:**
- Modify `Packages/Core/Sources/Core/Events/SuperEvent.swift`.
- Modify `Packages/Chat/Sources/Chat/UI/BibleDeepLinkRouting.swift`, `ChatScreen.swift` (routing comments), and `Packages/Chat/Tests/ChatTests/UI/BibleDeepLinkRoutingTests.swift`.
- Modify `App/Shell/AppShell.swift`; create `App/Shell/RecordPreviewPresentation.swift` for presentation identity/content/completion ownership.
- Modify both explicit source lists in `project.yml`; regenerate project files using existing repository conventions.
- Update `docs/Chat/UI_STRUCTURE.md` and stale routing comments in `BibleReferenceInbox` and `BibleScreenViewModel`.

**Interfaces:** `SuperEvent.previewRecord(reference: RecordReference)` requests presentation only. Existing `.openRecord` and `.recordAddedToChat` retain their payloads/consumers. The shell's presentation record owns one opaque view and unique ID; the callback is guarded by that ID and consumed once on dismissal.

- [x] Change the existing real-bus router test to expect `.previewRecord`. Preserve malformed URL, https fallback, and nil-bus behavior. Add a Bible-inbox regression proving preview events do not call full-reader navigation while `.openRecord` still does.
- [x] Add the event and route transcript links to it. Keep `AppShell.onOpenURL` on the full-navigation path.
- [x] Resolve applet capability and cache the returned content on accepted preview requests. Wrap cached content with live `.superTheme(theme)`, `.superFontScale(appearance.fontScale)`, `.superTypography(typography)`, and shared event-bus/haptics environment at the shell layer. Resign composer focus and present the outer native sheet without altering activeID, chat state, or overlay progress. Verify nondefault theme/scale from actual Chat, not only a directly hosted preview fixture.
- [x] Implement identity-checked completion, outer-dismiss publication, duplicate suppression, Settings arbitration, and cancellation of queued preview work on authoritative navigation/sidebar events. A cancelled request never emits a stale Open/Add-to-chat event. The nested presenter finishes before the outer one. For an already-published authoritative `.openRecord`, defer only the shell transition: never replay the original event because BibleReferenceInbox already consumed it. Preview-originated completions publish their first event from outer onDismiss.
- [x] Add the new shared source to both schemes. Manually validate shell-only state transitions on the dedicated simulator under the documented app-target XCTest exception; no new app test target solely for this change.
- [x] Run full Core/Chat/Bible package suites and build both app schemes; commit the integrated behavior.

Update the existing routing regression to this event expectation before changing
the router. This test fails against the current `.openRecord` behavior:

```swift
@Test func validBibleURLRequestsPreview() async throws {
    let bus = SuperEventBus()
    let stream = await bus.events()
    var events = stream.makeAsyncIterator()
    let url = try #require(URL(string:
        "super://bible/verse?book=ROM&chapter=8&verses=28-30"))
    #expect(BibleDeepLinkRouter.handle(url: url, eventBus: bus))
    let event = await events.next()
    guard case .previewRecord(let reference) = event else {
        Issue.record("Expected a preview request, got \(String(describing: event))")
        return
    }
    #expect(reference.sourceID == "ROM/8/28-30")
}
```

## Task 5: Verify visual/native behavior and complete PR workflow

**Files:**
- Create `Packages/Bible/Tests/BibleTests/UI/Snapshots/BibleChapterPreviewSheetSnapshotTests.swift`.
- Update `Scripts/VisualTesting/package-inventory.json` and inventory counts in testing documentation if required by the new captures.
- Update this plan's checkboxes and design status after approval/implementation.

- [x] Read `docs/TESTING.md`, `docs/VISUAL_TESTING_POLICY.md`, and current simulator pins again only if changed. Reconfirm the verified inventory (623 total; Bible 276). Add three modal-content captures: primary light/dark and XXL plus maximum app scale (target total 626; Bible 279). Existing single-pass captures cannot prove native sheet stacking; test that on the dedicated simulator and record demo evidence without new capture infrastructure.
- [x] Run `swift test --package-path Packages/Core`, `swift test --package-path Packages/Chat`, and `swift test --package-path Packages/Bible`.
- [x] Run `xcodegen generate`, then `python3 Scripts/worktree_simulator.py ensure`; reuse the returned UUID. Build `Super` and `SuperBible` with `xcodebuild build -scheme <scheme> -destination "platform=iOS Simulator,id=<UUID>" CODE_SIGNING_ALLOWED=NO`.
- [x] Use `python3 Scripts/VisualTesting/capture.py Bible --output .build/chat-verse-preview-bible-capture` with a fresh output directory; run relevant Core/Chat simulator tests for changed renderer behavior. Inspect the three modal captures and existing full-reader/action/narration regression evidence.
- [ ] In both apps, use DebugLLMProvider's existing verse-citation response. Tap a citation from expanded Chat; verify selection and scroll; deselect/reselect behind actions; close/reopen actions; highlight/copy/share; create/edit/cancel a note; generate/retry annotation; cancel by X and swipe; reopen; Open in Bible; Add to chat/New chat. Confirm underlying reader state survives cancel and intended writes remain visible. Verify external deep links still navigate directly and race cases never publish stale completions.
- [x] Have a separate review subagent inspect the implementation for serious actionable issues. Address findings and repeat affected checks.
- [ ] Create a draft PR using `.github/pull_request_template.md`: include package/simulator/build results, native demo evidence, capture count delta with reasons, and any exact toolchain-related missing verification.
- [ ] Monitor CI and Codex review together every ten minutes with a scheduled wakeup; request a Codex pass if none starts. Fix failures/findings with auto-merge disabled. Only after explicit approval and passing applicable CI for the current head, mark ready and enable auto-merge with required checks enforced; verify the eventual merge and stop monitoring.

## Review log

Two independent reviewers supported the architecture and identified three gaps:
live shell appearance injection, a Core renderer policy for inert citations, and
preserving full-reader study-sheet return behavior. The tasks now address all
three. Self-review and reviewer discussion also added exact selection/translation
handoff, no replay of authoritative navigation, native readiness signaling, and
three feasible modal captures plus real simulator stack verification. Both
reviewers approved the final revisions with no remaining serious issues. The
architecture reviewer additionally approved one-time/coalesced initial restoration
with navigation/translation precedence tests. The user approved implementation and
stacked PRs on 2026-09-08.

Repository snapshot restoration: the stack now includes main's PR #354 rollback. The preview layer explicitly recorded and inspected its three new modal baselines on pinned Xcode 26.4.1/iOS 26.4.1 after default comparison rejected the missing files. Existing baselines and rendering tolerances are preserved. The integration layer updates those same three files for the final approved floating-pill design. Live protection was verified to require build, lint, gitleaks, ios-test, swift-test, and native-previews with their existing GitHub Actions app bindings; Argos is no longer a gate.

## Validation record — 2026-09-08

Implementation and both corrective changes are independently approved at
`8deba815`. The review found an unmounted study-sheet finish race; its regression
now proves early Cancel/Open finishes without manufacturing an impossible native
`onDismiss`. Native QA additionally found the outgoing Chat composer consuming
New chat attachments during asynchronous model creation. New conversation
references now travel directly to the destination model, with real-bus regressions
for empty composers, repeated references, reservation bursts, and the send payload.

- Local package suites: Core **326 / 41 suites**, Chat **1106 / 83 suites**, Bible
  **884 / 89 suites**, all passing. Final Chat changes reran its complete suite;
  Core/Bible source is unchanged since their passing runs.
- Both `Super` and `SuperBible` build at `8deba815` on the pinned Xcode 26.4.1 /
  iOS 26.4.1 iPhone 17 simulator. Dedicated UUID:
  `1E3A690B-F069-43F0-974D-7DB5CE1C289F`.
- Local complete Bible capture: **279 validated images**; complete Core capture:
  **20 validated images**. Existing reader, selection, notes, bookmarks, narration,
  and chapter-footer representatives were inspected. Three new modal captures
  cover Vellum light/dark and XXL with 120% app scale. Inventory: **623 → 626**,
  Bible **276 → 279**, package **582 → 585**, native unchanged at **41**.
  CI also passed complete Chat/Core/Bible/Todo capture legs on the lower stack.
- Native SuperBible: semi-expanded and expanded Chat open a real nested sheet;
  range selection, deselection to **28,30**, action close/reopen, highlight, exact
  clipboard contents, Cancel/reopen, and exact-selection Open in Bible pass.
  A saved note remained editable; an external Psalm 23:1 link while its editor
  was open dismissed the whole preview stack and opened the authoritative target.
  Lapis Dark and 120% app font scale propagated from actual Chat.
- Native annotation generation: first-use disclaimer, chapter and verse generation,
  close/reopen persistence, and secondary presentation pass. The actual preview
  renderer exposed the Hebrews 4:15 citation as StaticText, with no link styling
  or navigation on tap. Core syntax-tree tests separately prove link nodes are
  removed, including explicit/reference-style links and preserved external URLs.
- Native SuperOS: preview opens from fully expanded Chat over Tasks; Share opens
  above actions and cancels without sending; swipe dismissal preserves Chat and
  Tasks. Whole-chapter Open in Bible navigates to Psalm 23 with empty selection
  and full controls, including before the full Bible screen's first mount.
- Native New chat regression at the corrected revision: empty-composer and
  Add-to-chat → New-chat with the same verse both retain exactly one destination
  attachment. The selected reference also survives the real Chat send pipeline.
- Duplicate/early-tap smoke checks did not create duplicate/orphan sheets. UIKit
  can ignore taps during its transition, so these are not claimed as deterministic
  race coverage. Deterministic preview/dispatch tests cover unmounted/mounted
  finishing, stale identities, retry completion, cancellation during generation,
  invalid/huge bounds, unavailable text, and last-verse selection/scroll targets.

The full Cartesian manual matrix in Task 5 is intentionally still unchecked:
annotation failure/retry and every native timing permutation were not manually
forced in both apps. Those state transitions have deterministic package coverage;
representative actual native flows above cover composition and presentation.
No generated images or simulator data are committed.

### PR delivery

The implementation is split into reusable reader foundation (PR #348), isolated
chapter preview (PR #349), and Chat/shell integration (top PR), linked through native
GitHub stack #350. Both lower PRs have explicit Codex approval of their current
heads and passing builds, lint, secret scan, package tests, and iOS capture tests.
At that historical revision, the required upload was blocked by Argos quota.
PR #354 subsequently restored repository snapshots and removed the Argos gate;
the stack rebase and current baseline validation below supersede that blocker.


## Design feedback — selection location and title

The user requested moving the selected-verse pill from the top to the bottom of
the modal and including verse numbers in the header. This is a bounded adjustment
to the existing preview view. Use the reader's current `selectionCitation` as the
SheetNavBar title, falling back to the chapter label for an empty selection. Move
the existing SelectionPill after the flexible chapter content in the VStack, with
vertical spacing above the modal's bottom safe area. This reserves space for the
pill rather than covering chapter text. Keep its existing reopen/clear actions,
with native study sheets continuing to present above the whole modal.

Risks: title truncation at large text sizes and reachability of final chapter
verses above the bottom control. Reuse the existing three preview captures with
unchanged inventory; inspect light/dark and XXL plus 120% app scale. Run the Bible
suite and a native simulator check for initial/range/disjoint/cleared titles and
selection actions. Update the top PR and request fresh current-revision review;
lower stack revisions remain unchanged.


Design feedback validation: the amended plan and code received independent
subagent approval. All **884 Bible tests / 89 suites** passed; the three existing
preview simulator captures passed and were inspected in light, dark, and XXL with
120% app scale. Capture inventory remains **626**. Both SuperBible and Super build
successfully. Native SuperBible at Lapis Dark / 120% verified range title
`1 Corinthians 13:4-7`, live disjoint title `1 Corinthians 13:4, 6-7`, bottom-pill
action reopening, clear-to-chapter title, and the entire final verse scrolling
above the reserved control area. No new model state, formatting logic, captures,
or generated image files were added. This view-only follow-up reuses existing
selection-formatting tests rather than adding tests that mirror the layout.


## Design clarification — floating selection pill

The user's clarification supersedes the reserved bottom-row layout: the pill must
float in front of the chapter, with text scrolling behind it. Keep the existing
verse-aware header. Move SelectionPill into a bottom-aligned overlay on the chapter
content; keep the overlay's hit area limited to the pill so surrounding text stays
interactive. Add trailing scroll content clearance while selected, sufficient for
the fixed 44-point pill and its spacing, so the final verse can scroll above it.
Do not shrink the ScrollView viewport or add a full-width opaque footer. Native
study sheets keep their existing presentation order.

Validation: independent bounded review, full Bible suite, the existing light/dark/
XXL preview captures with unchanged inventory, and native scrolling behind the
pill, bottom-verse reachability, action reopening, and clearing. Update the top PR
and request renewed Codex review, with auto-merge disabled.

### Incorporate the repository snapshot rollback

- Checkpoint the reviewed floating-pill correction, then preserve recovery refs for all three current stack heads.
- Rebase the foundation onto fetched `origin/main`, then replay preview and Chat integration in dependency order with explicit old parent boundaries. Keep the native stack and PR bases intact; do not sync against another checkout's local main.
- Preserve the restored repository baseline workflow, simulator/renderer pins and existing PNGs. Resolve overlapping inventory documentation to include the three distinct modal fixtures (623 → 626 total).
- Run default comparisons before explicitly recording the three intentional modal baselines. Inspect PNGs, commit them on the preview branch, then update the three on the integration branch for the final verse-aware floating-pill design. Recompare each changed baseline set.
- Run affected Core, Bible and Chat suites, build both app schemes, and check the rebase diff. Push each owned branch with an explicit lease matching its pre-rebase remote head, request fresh Codex review, and update the ten-minute monitor to use repository snapshot checks with no Argos dependency.

Risks: retain each PR's independently valid baselines; do not accidentally flatten the stack, replay parent commits twice, or accept unrelated visual changes. All PRs are draft with auto-merge disabled before rewriting. Fresh approval and required checks apply to every rewritten head.

Floating-pill validation: Bible passed 884 tests in 89 suites; all three existing preview captures passed and were inspected (light, dark, XXL at 120%). Super and SuperBible both built on the pinned simulator. Native SuperBible at Lapis Dark/120% confirmed text behind the fixed pill, a verse tap beside the pill updating both citations, and the complete final verse scrolling above the pill. Independent plan and code reviews approved the correction. Capture count is unchanged by this layout adjustment.


Post-rebase validation: Core 326/41, Bible 884/89 and Chat 1106/83 pass. All 623 restored main PNGs, original inventory rows, snapshot scripts, workflows and renderer pins remain byte-identical to main. The three preview-layer images were explicitly recorded, inspected and compared successfully. The integration layer changes those same three images to show the verse-aware title and floating bottom selection; default comparison rejected exactly those intentional differences before recording. No extra capture was added. Independent rebase review found no source regression.

The final three floating-pill comparisons pass with recording disabled. Both Super and SuperBible build after the rebase. The separate reviewer approved the final three PNGs in light, dark and XXL/120% with no actionable visual findings.

### Design follow-up — hide the chapter modal handle

Hide the native drag indicator on both the shell's record-preview presentation and the Bible chapter sheet, which currently both request a visible handle. Preserve native dismissal, the SheetNavBar controls and selection behavior. The nested verse-action sheet keeps its existing presentation.

Validation: build both app schemes; run the Bible package suite and the existing three modal-content comparisons without recording. Verify the real native modal has no outer handle, still opens/closes actions, and still supports swipe dismissal. This shell-owned chrome is covered by native QA under the documented app-target exception; no new snapshots or layout tests are needed. Update the current integration PR and request review of its new head.

Validation passed: both app builds, all 884 Bible tests, and all three existing modal-content comparisons with recording disabled. No baseline or capture-count change. Native SuperBible at Lapis Dark/120% shows no outer handle, retains the verse title/floating pill, opens and closes child actions, and dismisses by swiping back to the same Chat. Independent plan and code review approved the two-line correction. Scoped lint introduced no diagnostics; the three pre-existing AppShell warnings were reproduced identically from the prior revision. `git diff --check` passes.
