# Chat Verse Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Use separate subagents for plan and final implementation review. Steps use checkbox syntax for tracking.

**Goal:** Open chat Bible citations in a temporary chapter modal with editable verse selection and an explicit Open in Bible handoff.

**Architecture:** Separate `.previewRecord` from `.openRecord`, with applet-owned opaque preview content presented by the shared shell. Compose the preview and full reader from shared chapter/study views, using isolated reading models and an applet-lifetime annotation dispatcher.

**Tech Stack:** Swift 6, SwiftUI native sheets, Observation, GRDBQuery, SuperEventBus, Swift Testing, VisualTestSupport/Argos.

**Spec:** [Chat verse preview design](../specs/CHAT_VERSE_PREVIEW_DESIGN.md)

## Global constraints

- Workspace: `/Users/bwang/.codex/worktrees/3773/Super`; edit only this worktree.
- No applet-to-applet imports; shared shell imports Core/Chat and opaque MiniApplet values.
- No new persistent tables, dependencies, provider APIs, or cross-applet imports.
- Temporary chapter/selection state; explicit highlight/note/bookmark edits remain persistent.
- Native `.sheet`, existing `SheetNavBar`, `SuperTypography`, and `SuperGlass` only.
- Decorations stay GRDBQuery `@Query` with a chapter-specific reader identity.
- Xcode 26.4.1 (`17E202`), iOS 26.4.1 (`23E254a`), iPhone 17; confirm live pins before QA.
- New public declarations/test suites have short documentation; async tests use completion seams, never sleeps/polling.
- Preserve existing capture coverage; Argos is the sole baseline; no committed visual PNGs.

## Task 1: Share annotation dispatch without sharing reader state

**Files:**
- Create `Packages/Bible/Sources/Bible/ViewModels/BibleAnnotationDispatchViewModel.swift`.
- Modify `Packages/Bible/Sources/Bible/ViewModels/BibleScreenViewModel.swift` and `Packages/Bible/Sources/Bible/Applet/BibleApplet.swift`.
- Test `Packages/Bible/Tests/BibleTests/ViewModels/BibleAnnotationDispatchViewModelTests.swift` and existing dispatch/disclaimer tests.

**Interfaces:** `@Observable @MainActor final class BibleAnnotationDispatchViewModel`; `attach(to: SuperEventBus) async`; `status(for: BibleAnnotationTargetSpec) -> BibleAnnotationDispatchStatus?`; `request(reference: RecordReference, for: BibleAnnotationTargetSpec) -> BibleAnnotationDispatchResult`; `clearFailure(for:)`. `BibleAnnotationDispatchResult` has `.started(requestId: String)`, `.alreadyRunning(requestId: String)`, and `.unavailable`. Only `.started` publishes. The local reader presents the target for the first two outcomes and retains the existing bus-less fallback for `.unavailable`.

- [ ] Add real-bus tests: two models share one running request; duplicate request publishes once; matching completion updates both; stale completion cannot clear a retry; preview model release does not lose running/failure state. Subscribe before publishing and drain explicit processed-event seams.
- [ ] Run `swift test --package-path Packages/Bible --filter BibleAnnotationDispatchViewModelTests`; new coverage should initially fail for the missing dispatch type.
- [ ] Move only bus request/status ownership into the shared model. Preserve full-reader forwarding APIs and test drain seams; keep disclaimer queues, selection, presented sheets, and text construction on each reader model. Attach once in `BibleApplet.attach(to:)`.
- [ ] Run new tests and `BibleScreenViewModelDispatchTests`, `BibleScreenViewModelAnnotationsTests`, and `BibleScreenViewModelSidebarTests`. Confirm existing narration attachment and sidebar dismissal still work.
- [ ] Commit the tested extraction.

## Task 2: Make chapter content and study presentation reusable

**Files:**
- Create `Packages/Bible/Sources/Bible/UI/BibleChapterNavigation.swift`, `BibleChapterReaderLayout.swift`, `BibleChapterContent.swift`, and `BibleStudySheetsModifier.swift`.
- Modify `Packages/Bible/Sources/Bible/UI/BibleChapterReader.swift`, `BibleScreen.swift`, and `BibleBottomOverlayKind.swift` where ownership comments change.
- Extend `Packages/Bible/Tests/BibleTests/UI/BibleChapterReaderTests.swift`, existing reader snapshots and selection/sheet behavioral tests.

**Interfaces:** `BibleChapterNavigation` contains previous/next labels and callbacks; `BibleChapterReaderLayout` has `topInset` and `bottomInset` with static full-reader/preview presets. `BibleChapterContent` takes the model, layout, optional navigation, overlay kind, study callbacks, and full-reader scroll/footer callbacks. `BibleStudySheetsModifier` takes the model, annotation repository, optional full-reader narration-sheet content, a Bible-link policy, an add-to-chat callback, and a host-completion callback.

- [ ] Capture existing full-reader expectations before moving code: selection survives action close, empty selection closes actions, selection-to-note/annotation waits for dismissal, narration replaces action content, and footer visibility still hides composer arrows.
- [ ] Change `BibleChapterReader` to render `BibleChapterFooter` only when navigation exists. Replace hardcoded layout clearances with the layout input and preserve the existing overlay reserve and pending-scroll consumption behavior.
- [ ] Extract the common content binding and study-sheet presentation from `BibleScreen`. Keep book/translation pickers, narration lifecycle, immersive behavior, shell chrome, and composer accessories owned by the screen. Route book-picker handoffs into the shared study presentation without duplicate sheet presenters.
- [ ] Make replacement handoffs explicit and identity-guarded: action tiles capture targets, clear selection/dismiss actions, and run the queued transition from `onDismiss`. Glyph-driven note/annotation presentation preserves selection. Bookmarks keep their existing clear-selection behavior and action-dismissal handoff (retain `presentClearsSelection`). Add narration → note/bookmark → close coverage proving playback and transport return, without expecting bookmark selection retention. Expose an asynchronous finish path that dismisses study sheets before completing the host. Do not use timer delays or attach a second selection sheet to the same host.
- [ ] Add behavioral tests for absent navigation and full-reader layout parity. Reuse existing `BibleScreenSnapshotTests` and `BibleChapterReaderTests` to verify the refactor; do not add captures solely for extracted wrappers.
- [ ] Run affected Bible tests and relevant simulator reader/action/narration fixtures; commit only once existing behavior remains intact.

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

- [ ] Add tests with injected text, storage, clock, IDs, clipboard, and haptics. Opening/cancelling must leave the original model and reading-position repository unchanged; selection/highlight/note edits target only the preview chapter; unavailable text never opens actions.
- [ ] Cover single/range/chapter links, partial/fully out-of-range verse spans, very large bounds, re-opened identical references, and exact current-selection handoff (contiguous, disjoint, empty) with captured translation. Round-trip `BibleReaderReference`; reject unknown versions, translation IDs, books, invalid chapters, malformed lists, and nonpositive verses. Filter actual loaded verse numbers against range bounds rather than constructing an unbounded `Set(start...end)`. Keep attachment and public URL grammars unchanged.
- [ ] Implement the nil-default generic capability and its Bible implementation. Retain/share dependencies inside BibleApplet rather than opening new databases or using hidden globals. Create content/model once per accepted request and inject the same read-only DatabaseContext.
- [ ] Resolve the full reader's initial saved state once during `BibleApplet.attach(to:)`, before inbox subscription and shell readiness; make `load()` idempotent and coalesce concurrent callers onto the same awaited restoration task. An initialization/navigation generation guard must prevent an in-flight restore from overwriting explicit chapter/translation navigation. Test a cold launch with a non-Bible backdrop and saved nondefault translation, explicit handoff before first BibleScreen mount, repeated/concurrent load, and gated restore versus navigation. Initialization must never persist a new reading position.
- [ ] Build the preview header, selection controls, shared chapter content, and shared study sheets. Fix the chapter/translation; omit all navigation/narration contributions. Gate initial actions with a one-shot `BiblePreviewPresentationObserver` native completion callback, checking the request ID and cancellation state. Do not equate SwiftUI `.task`/`.onAppear` with presentation completion. Preserve pending verse scrolling until the reader consumes it.
- [ ] Implement Core's scoped `.plainText` citation rendering: bypass automatic linkification and unwrap explicit Bible-scheme links to their label nodes (including reference-style syntax), preserving formatting, code, and external URLs. Carry the policy through the annotation sheet/container/block chain and retain default enabled behavior elsewhere. Test automatic references, inline/reference-style internal links, mixed external/internal links, code, and default Chat/full-Bible rendering. Retain defensive custom-scheme rejection in BibleMarkdownRendering. Verify disabled citations lack VoiceOver link traits; do not implement this as a no-op tap handler.
- [ ] Validate action close/reopen, last-verse scrolling, secondary note/annotation/bookmark sheets, and finish callbacks. Ensure dispatched generation and accepted writes survive dismissal while queued presentation work does not.
- [ ] Run Core/Bible tests affected by the capability and model changes; commit the tested preview.

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

- [ ] Change the existing real-bus router test to expect `.previewRecord`. Preserve malformed URL, https fallback, and nil-bus behavior. Add a Bible-inbox regression proving preview events do not call full-reader navigation while `.openRecord` still does.
- [ ] Add the event and route transcript links to it. Keep `AppShell.onOpenURL` on the full-navigation path.
- [ ] Resolve applet capability and cache the returned content on accepted preview requests. Wrap cached content with live `.superTheme(theme)`, `.superFontScale(appearance.fontScale)`, `.superTypography(typography)`, and shared event-bus/haptics environment at the shell layer. Resign composer focus and present the outer native sheet without altering activeID, chat state, or overlay progress. Verify nondefault theme/scale from actual Chat, not only a directly hosted preview fixture.
- [ ] Implement identity-checked completion, outer-dismiss publication, duplicate suppression, Settings arbitration, and cancellation of queued preview work on authoritative navigation/sidebar events. A cancelled request never emits a stale Open/Add-to-chat event. The nested presenter finishes before the outer one. For an already-published authoritative `.openRecord`, defer only the shell transition: never replay the original event because BibleReferenceInbox already consumed it. Preview-originated completions publish their first event from outer onDismiss.
- [ ] Add the new shared source to both schemes. Manually validate shell-only state transitions on the dedicated simulator under the documented app-target XCTest exception; no new app test target solely for this change.
- [ ] Run full Core/Chat/Bible package suites and build both app schemes; commit the integrated behavior.

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

- [ ] Read `docs/TESTING.md`, `docs/VISUAL_TESTING_POLICY.md`, and current simulator pins again only if changed. Reconfirm the verified inventory (623 total; Bible 276). Add three modal-content captures: primary light/dark and XXL plus maximum app scale (target total 626; Bible 279). Existing single-pass captures cannot prove native sheet stacking; test that on the dedicated simulator and record demo evidence without new capture infrastructure.
- [ ] Run `swift test --package-path Packages/Core`, `swift test --package-path Packages/Chat`, and `swift test --package-path Packages/Bible`.
- [ ] Run `xcodegen generate`, then `python3 Scripts/worktree_simulator.py ensure`; reuse the returned UUID. Build `Super` and `SuperBible` with `xcodebuild build -scheme <scheme> -destination "platform=iOS Simulator,id=<UUID>" CODE_SIGNING_ALLOWED=NO`.
- [ ] Use `python3 Scripts/VisualTesting/capture.py Bible --output .build/chat-verse-preview-bible-capture` with a fresh output directory; run relevant Core/Chat simulator tests for changed renderer behavior. Inspect the three modal captures and existing full-reader/action/narration regression evidence.
- [ ] In both apps, use DebugLLMProvider's existing verse-citation response. Tap a citation from expanded Chat; verify selection and scroll; deselect/reselect behind actions; close/reopen actions; highlight/copy/share; create/edit/cancel a note; generate/retry annotation; cancel by X and swipe; reopen; Open in Bible; Add to chat/New chat. Confirm underlying reader state survives cancel and intended writes remain visible. Verify external deep links still navigate directly and race cases never publish stale completions.
- [ ] Have a separate review subagent inspect the implementation for serious actionable issues. Address findings and repeat affected checks.
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
