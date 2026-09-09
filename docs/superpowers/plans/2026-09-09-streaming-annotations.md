# Streaming Annotations Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development to execute the reviewed plan. The primary agent owns integration; a bounded provider-completion subtask can run independently. A plan-review subagent critiques this document before code changes and a separate review subagent reviews the implementation afterward.

**Goal:** Open annotations immediately and stream their Markdown into a composer-free reading surface, using shared Chat response components.

**Architecture:** Keep the native Bible annotation sheet and its GRDBQuery subscription. Extract domain-free response UI from Chat into Core. Foreground annotation requests stream ordinary Markdown through the same `LLMProvider` abstraction used by Chat, then invoke the existing `bible.annotate` executor exactly once with the selected target and completed text. Cross-applet progress travels through `SuperEventBus`; Bible never imports Chat.

**Tech Stack:** Swift 6.2 language mode, SwiftUI, Observation, AsyncStream, GRDB/GRDBQuery, existing Core MarkdownUI renderer, Swift Testing, repository visual snapshots.

**Spec:** User-approved visual prototype in this task, with the book/reference selector removed. The specification below records the approved behavior and implementation decisions so the plan is self-contained.

## Global constraints

- Edit only `/Users/bwang/.codex/worktrees/e359/Super`; it is already a linked worktree, initially clean and detached at `0d9e46ef`.
- Applets import Core, never another applet. Core owns domain-free brand UI; Bible owns annotation layout and database state.
- Retain the native `.sheet`, current citation header, close button, overflow actions, verse quote, citation navigation, and first-use disclaimer.
- No book/reference selector, text composer, model picker, keyboard entry, or automatic creation of a visible Chat conversation.
- The quoted verse is available before any model output. Chapter/book targets omit the quote; all targets use the citation header.
- Stream actual model deltas; do not reveal a completed answer with a simulated typewriter. The first-token latency still depends on the provider.
- Save only successful, complete, nonempty output. Never persist partial text or delete the prior annotation before replacement succeeds.
- Preserve in-chat `bible.annotate` behavior and the bulk `BibleAnnotateGenerating.generate(reference:)` tool-loop path, including notable-verses multi-call generation.
- Typography uses `SuperTypography` and `MarkdownBodyMetrics`; glass uses `SuperGlass`; honor Reduce Motion and the app font scale.
- Tests use fake/debug providers only. No real model calls or API keys for validation.

## Design and decisions

### Reading surface

The sheet contains one stable `ScrollView` and a leading-aligned response area. A verse-range quote sits above the response from the first frame. Remove the current framed annotation card and duplicate citation heading within the sheet. Render the live and saved response through the same shared block; do not replace the entire scroll view at completion or issue scroll commands on deltas. Reuse Chat's partial-Markdown treatment and activity spark. Hide the spark at completion and show shared Copy/Regenerate controls plus the existing provenance footer. Retain Add to chat/Delete in the overflow menu for the saved annotation. Disable mutations while a request is running.

Closing a sheet does not cancel generation. Reopening the same target shows its current accumulated text. Requests for different targets can run concurrently; re-triggering an already-running target reopens that request instead of launching a competing writer.

On a first-generation failure, keep partial text and place an inline error/retry below it. A regenerate failure keeps the stored annotation intact; if partial text exists, offer a way to return to the saved annotation as well as retry. Before-first-token failure still shows the quote and a useful error. Do not label partial text as saved or offer Add to chat/Delete for a draft. Delete operates on the saved record and clears any settled draft/status only after the delete succeeds.

### Shared components

The existing `ChatComposer` is the input region and has no reusable prose renderer. The useful extraction comes from `StreamingTail`, `AssistantMessage`, `WaitingSpark`, `MessageActionButton`, and `SparkIcon`.

Create in Core:

```swift
public struct ResponseTextBlock: View {
    public init(text: String, treatAsPartial: Bool = false, isWorking: Bool = false)
}
public struct ResponseActions: View {
    public init(onCopy: @escaping () -> Void,
                onRegenerate: @escaping () -> Void,
                isRegenerateDisabled: Bool = false)
}
```

Move the activity spark/icon and action-button implementation into Core, preserving existing Chat-facing names where required with thin wrappers/typealiases. `ResponseTextBlock` owns only Markdown + optional activity indicator. Thinking/tool/source UI remains in Chat. `ResponseActions` owns the existing 4pt-spaced Copy/Regenerate row; pasteboard and confirmation side effects remain with its host. Chat's current geometry and snapshots should remain unchanged by extraction.

### Foreground generation and persistence

The provider adapters currently publish complete tool inputs only, so streaming the existing `summary` tool parameter would require partial JSON parsing and changing several provider reducers. Instead, a small foreground-only `BibleAnnotationStreamGenerator` consumes ordinary `.textDelta` values with tools disabled. It captures the active provider/model once, uses the existing annotation grounding and section guidance, and instructs the model to output just the Markdown study note. It ignores thinking and rejects unexpected tool output, provider errors, cancellation, empty output, and an EOF without `.messageComplete`.

After successful stream completion, construct the tool parameters from the selected `RecordReference.sourceID` (not from model output), set `summary` to the accumulated text, and call `ToolRegistry.execute(toolID: "bible.annotate", input:)`. The existing Bible executor validates and atomically replaces the annotation. Publish the existing terminal outcome only after that write succeeds. No transient chat records are needed on this foreground path. The existing `generate(reference:)` remains the bulk tool-loop implementation.

**Reviewed completion requirement:** `.messageComplete` is currently synthesized at EOF by the remote reducers and alone does not prove successful output. Add `LLMRequestOptions.requiresCompleteResponse: Bool = false`. The foreground generator passes `true`; built-in remote adapters thread it into reducers, which emit an error before terminal completion when the native stream lacks successful completion evidence. OpenAI Chat requires `finish_reason == "stop"` (or a complete tool termination, which this generator separately rejects); Anthropic requires `message_stop` with `end_turn`/`stop_sequence`/`tool_use`, never `max_tokens`; Gemini requires `finishReason == "STOP"`; Responses requires `response.completed`, rejecting `response.incomplete`, `response.failed`, cancellation, and bare EOF. Error paths must not be overwritten by completion. Default-false behavior preserves normal Chat/bulk event contracts. Apple Foundation already reports errors when its native stream fails; verify its successful completion and cancellation paths. Keep strictness as a local normalization option, not a wire parameter or prompt change.

Strict target decoding accepts only these aligned sourceID/kind shapes:

| Kind | Source ID | Tool target |
| --- | --- | --- |
| `book` | `book:ROM` | `book` |
| `chapter` | `chapter:ROM:8` | `chapter` |
| `verseRange` | `verse:ROM:8:28:30` | `verse` |

Require `appletID == "bible"`, exact component counts, nonempty book ID, positive positions, and ordered verse ranges before making a provider call. Unsupported kinds (including bulk-only `chapterVerses`) never enter this foreground path. The final writer checks actual target validity as today.

Retain the existing annotation stamp provider and its documented active-model provenance limitation (#143); no new tool execution context is introduced in this change. Preserve existing provider failure classification for bulk callers.

### Cross-applet state and query handoff

Add an additive Core event:

```swift
// SuperEvent:
case bibleAnnotateProgress(requestId: String, text: String)
```

The generator accepts `onProgress: @Sendable (String) async -> Void`, carrying cumulative Markdown. The dispatcher forwards those updates onto its attached bus under the original reference ID, preserving ordering by awaiting each publish. Add the event to the shared shell's exhaustive ignored-event case and build both app targets.

Bible retains a per-target `BibleAnnotationDraft` (request ID, accumulated text, `isComplete`) separately from existing `.running`/`.failed` dispatch status. Progress is accepted only for the matching running request. A fresh request resets that target's draft; late progress/completion from an older request is ignored. Dismissal/navigation does not erase an active draft.

On successful completion, mark the draft complete, remove the running status, and retain the final text as a bridge. A new `AnnotationSheetRequest(spec:completedRequestID:)` wraps `BibleAnnotationsByTargetRequest.fetch`, returning an optional `AnnotationSheetSnapshot` with rows and the same request ID (default nil means unloaded). The completed request ID is part of request equality, forcing @Query to fetch again after the save has finished. Until the returned snapshot tag matches, show the complete draft. Once it matches, trust that fresh read, including an empty result or an externally replaced row, and clear only the matching settled draft. Reopening a completed sheet uses the same fresh tagged query. A pure presentation projection tests this causal handoff; no record-ID baseline tracking or manual observation is needed.

## Task 1 — Foreground stream and event contract

**Files**

- Modify `Packages/Core/Sources/Core/Events/SuperEvent.swift` documentation/event cases.
- Modify `App/Shell/AppShell.swift` to ignore the new progress event in its exhaustive switch.
- Create `Packages/Chat/Sources/Chat/Orchestration/BibleAnnotationStreamGenerator.swift` and `BibleAnnotationRequestTarget.swift`.
- Modify `Packages/Chat/Sources/Chat/Orchestration/BibleAnnotateDispatcher.swift` bus handling only; share section/grounding prompt material without changing bulk output instructions.
- Add `Packages/Chat/Tests/ChatTests/Orchestration/BibleAnnotationStreamGeneratorTests.swift`.
- Update `BibleAnnotateDispatcherTests.swift`: retain tool-loop assertions as direct `generate` tests; use real bus tests for foreground stream forwarding.

**Interfaces**

```swift
struct BibleAnnotationStreamGenerator: Sendable {
    init(providerRegistry: LLMProviderRegistry, toolRegistry: ToolRegistry)
    func generate(reference: RecordReference,
                  onProgress: @Sendable (String) async -> Void)
        async -> BibleAnnotateOutcome
}
struct BibleAnnotationRequestTarget: Sendable {
    init(reference: RecordReference) throws
    func parameters(summary: String) -> [String: JSONValue]
}
```

- [x] Add a regression using a strict scripted provider with `textDelta("First ")`, `textDelta("paragraph.")`, then `.messageComplete`. Assert ordered progressive text and one executor call containing exactly `"First paragraph."` and the request's target; before stream completion, assert zero writes with a gated stream.
- [x] Run the foreground regression through `BibleAnnotateDispatcherTests.foregroundTextIsSaved`; confirm text produces no progress or saved annotation before implementation.
- [x] Implement decoding, the single-provider stream with `requiresCompleteResponse: true`, terminal validation, and the existing tool save. Reject incomplete/failed output without execution. Retain text on the UI via prior progress events.
- [x] Add parameterized cases for all target kinds, mismatched/invalid target envelopes, thinking-only/empty/missing-terminal streams, unexpected tool calls, emitted/thrown errors, cancellation, write failure, and an unavailable/disabled annotation executor. Validate the executor before starting billable work as well as at save time.
- [x] Wire bus requests to the foreground generator. Deduplicate an identical request ID while it is in flight. Keep the public bulk protocol behavior untouched. Assert bus progress precedes completion; verify duplicate-ID guard by review and no foreground Chat rows through tests and simulator database inspection.
- [x] Re-run generator and dispatcher suites. Preserve fatal auth/quota and notable-verses multi-call tests.

### Task 1a — Provider completion validation (independent bounded subtask)

**Files:** Core `LLMRequestOptions.swift`/`LLMProvider.swift`; Chat's OpenAI Chat, OpenAI Responses, Anthropic, and Gemini provider/reducer files and required wire stop/status fields; corresponding reducer/provider tests. Do not change the annotation generator, Bible state, or UI in this subtask.

- [x] Add the opt-in request field, default false, and thread it through every remote adapter to its reducer; four-argument overloads forward with `.none`.
- [x] Add failing strict-mode reducer fixtures for EOF after partial text, explicit token limits/filter/refusal as applicable, Responses incomplete/failed, and successful native termination.
- [x] Emit a normalized error on unverified termination when strict mode is enabled. Preserve existing default event sequences and usage handling.
- [x] Add provider-level fixtures proving the five-argument option reaches each reducer and failures cannot be turned into success by the adapter's final `finish()`.
- [x] Run affected tests red/green and report results to the primary agent. The generator's strict flag assertion and adapter fixtures together cover the persistence boundary.

## Task 2 — Bible draft state and persistence handoff

**Files**

- Create `Packages/Bible/Sources/Bible/Models/BibleAnnotationDraft.swift`.
- Create `Packages/Bible/Sources/Bible/Queries/AnnotationSheetRequest.swift` and focused in-memory query tests.
- Modify `Packages/Bible/Sources/Bible/ViewModels/BibleScreenViewModel.swift` for progress, per-target drafts, duplicate-target guarding, and scoped cleanup.
- Add tests in `Packages/Bible/Tests/BibleTests/ViewModels/BibleScreenViewModelDispatchTests.swift` and a focused annotation presentation test file.
- Create `Packages/Bible/Sources/Bible/UI/AnnotationPresentation.swift` for deterministic state projection; keep database queries in the container.

**Interfaces**

```swift
public struct BibleAnnotationDraft: Sendable, Equatable {
    public let requestID: String
    public var text: String
    public var isComplete: Bool
}
// BibleScreenViewModel:
public func annotationDraft(for spec: BibleAnnotationTargetSpec) -> BibleAnnotationDraft?
public func clearAnnotationDraft(for spec: BibleAnnotationTargetSpec, requestID: String)
```

- [x] Add real-bus regressions proving progressive text survives dismiss/reopen, first-generation errors retain partial text, distinct targets remain isolated, and a second trigger for a running target does not dispatch again. Use a processed-progress continuation seam analogous to `_onNextDispatchCompletion`, never sleeps/polling.
- [x] Test that retry starts fresh, stale progress and stale completion do not replace a new request, and success retains the final draft until scoped query acknowledgement.
- [x] Run the affected view-model suite red, implement the new state/events, then run it green.
- [x] Test the pure presentation projection for initial wait, live text over an old record, interrupted text, delayed query delivery, matching tagged query arrival, external replacement/deletion, reopen after completion, and retry/clear races. Test the tagged request against an in-memory database. No broad view-model split or unrelated refactor.

## Task 3 — Extract shared response UI and adopt the approved sheet

**Files**

- Create Core response components under `Packages/Core/Sources/Core/UI/Responses/` (`ResponseTextBlock.swift`, `ResponseActions.swift`, `WaitingSpark.swift`, `SparkIcon.swift`, `MessageActionButton.swift`).
- Modify Chat `StreamingTail.swift`, `AssistantMessage.swift`, and the extracted original files to use the shared implementation/preserve public compatibility.
- Modify Bible `AnnotationSheet.swift`, `AnnotationSheetContainer.swift`, `AnnotationBlock.swift`, and `BibleScreen.swift`.
- Reuse Core's environment-injected `PasteboardClient` for Copy.

- [x] Preserve Chat's existing layout and control dimensions in the extraction, with `MarkdownText(..., treatAsPartial: true)` for the live block. Keep the inactive interrupted-tail and compaction spark behavior unchanged.
- [x] Replace the sheet's mutually exclusive spinner/card scroll containers with one scroll container and a stable response identity. Keep the quote independent of persisted rows and omit the prototype's book/reference selector entirely.
- [x] Render the shared response/actions, maintain citation link routing and provenance, and disable Regenerate/Add to chat/Delete while running or while showing an unsaved draft. A saved annotation remains accessible after failed regeneration through an explicit return-to-saved action.
- [x] Connect request-scoped acknowledgement/cleanup and handle delete errors without clearing stored UI state. Copy copies the displayed saved response through `PasteboardClient`, with a visible/accessibility confirmation.
- [x] Confirm Chat still uses the extracted components rather than retaining duplicate implementations.

## Task 4 — Deterministic manual preview and visual QA

**Files**

- Modify `Packages/Chat/Sources/Chat/LLM/DebugAnnotateLLMProvider.swift`: when tools are empty, emit the existing canned summary as timed text deltas; when annotation tools are present, keep existing tool behavior.
- Update `Packages/Chat/Tests/ChatTests/LLM/DebugBibleProvidersTests.swift` for the added text-only path.
- Update existing annotation sheet/container/block visual fixtures and their intentional PNG baselines.
- Update `Scripts/VisualTesting/package-inventory.json` only if adding an independently justified capture.
- Update `docs/Chat/UI_STRUCTURE.md` to describe the extracted Core response ownership.

- [x] Keep Debug provider Release exclusion. Use deterministic response chunks; unit tests use event gates, not its visual pacing as synchronization.
- [x] Reuse existing light/dark generating-over-populated captures for the first-token quote/spark layout. Reuse the representative completed sheet light/dark/XXL and long-content block coverage for the open transcript layout.
- [x] Add at most two focused sheet captures: a partial Markdown stream and an interrupted partial response with retry. These catch layout risks absent from existing loading and completed fixtures. Add a separate capture only if inspection proves another distinct uncovered risk.
- [x] Run default targeted comparisons first. Inspect expected/actual/diff images. Explicitly record only approved output changes, inspect new PNGs, then rerun comparison without recording. Report exact before/after capture counts.
- [x] Run `swift test` for Core, Chat, and Bible. Run affected UIKit suites on the pinned per-worktree simulator, and relevant Chat snapshots to verify extraction parity.
- [x] Build both Super and SuperBible (the shared shell's event switch changes). Exercise SuperBible verse, chapter, and book annotation entry points with Debug annotate; inspect first token, midstream, complete, close/reopen, regenerate, link navigation, and Copy. Confirm absence of composer/selector and no visible Chat conversation.

## Validation environment and commands

Use Xcode 26.4.1 (`17E202`), iOS 26.4.1 (`23E254a`), iPhone 17, XcodeGen 2.45.4. The machine's default Xcode is 27.0; select `/Applications/Xcode 26.app/Contents/Developer` explicitly after verifying its installed version. Simulator operations require access outside the shell sandbox.

```bash
DEVELOPER_DIR='/Applications/Xcode 26.app/Contents/Developer' xcodebuild -version
DEVELOPER_DIR='/Applications/Xcode 26.app/Contents/Developer' python3 Scripts/worktree_simulator.py ensure
DEVELOPER_DIR='/Applications/Xcode 26.app/Contents/Developer' swift test --package-path Packages/Core
DEVELOPER_DIR='/Applications/Xcode 26.app/Contents/Developer' swift test --package-path Packages/Chat
DEVELOPER_DIR='/Applications/Xcode 26.app/Contents/Developer' swift test --package-path Packages/Bible
xcodegen generate
```

Use the UUID returned by `ensure` for `xcodebuild test -scheme Chat` / `Bible` / `Core` with `-destination 'platform=iOS Simulator,id=<registered UUID>' -parallel-testing-enabled NO`; select affected suites during iteration. Use `Scripts/VisualTesting/capture.py --help` for its supported targeting/record arguments rather than inventing flags. Store logs/capture output in ignored `.build/` directories. Build `SuperBible` for the same simulator with local signing for interactive QA. If the pinned runtime is missing, report the exact missing verification and retain current baselines rather than recording with Xcode 27.

## Risks and containment

- **Provider terminal semantics:** require a real successful message completion before saving; transport cancellation/error cannot write a truncated annotation.
- **Concurrent requests:** deduplicate same-target foreground work and same-ID dispatcher requests; correlate every progress/cleanup event with its request ID.
- **Persistence/query timing:** hold the final draft until fresh query data becomes authoritative; never allow a late clear to erase a newer draft or pin a draft over later external writes.
- **Regeneration failure:** preserve old database rows, distinguish partial text from saved content, and retain an explicit route back to the saved version.
- **Prompt drift:** preserve existing source-grounding, length, section, and cross-reference constraints in the new text-only prompt; bulk/in-chat prompts stay unchanged.
- **UI extraction:** keep public `Chat.SparkIcon` compatibility and run the existing Chat visual cases. No extra shared UI abstraction beyond the response body, spark, and action row.
- **Existing provenance limitation:** active-model stamping is already documented in #143; do not expand this PR into a generic execution-context redesign.

## Review and delivery

- [x] Plan subagent reviews this file against code/AGENTS and reports serious actionable findings; resolve them before implementation.
- [x] Separate review subagent reviews the final diff, concurrency/persistence tests, and inspected visual changes. Fix findings and repeat affected validation.
- [ ] Create `codex/streaming-annotations`, commit reviewed work, and open a draft PR using `.github/pull_request_template.md` with test evidence and capture-count rationale.
- [ ] Monitor CI and Codex review together every 10 minutes using a scheduled wakeup while unchanged. Request a Codex pass if none starts.
- [ ] After explicit Codex approval of the current revision and passing applicable checks, mark ready, enable auto-merge without bypassing protections, and verify the eventual merge. Disable auto-merge before any subsequent push and require renewed checks/review.

## Execution log

- Initial repository state: clean linked worktree; no implementation edits before plan review.
- Existing annotation generation waits for a completed tool-use payload; Core provider events expose incremental text but not incremental tool arguments.
- The prototype is approved with its selector removed. This plan keeps that removal local to the annotation surface; the Bible reader's normal navigation remains available.
- Plan review: approved the foreground stream/save approach and component extraction; identified P1 synthetic terminal completion risk. Addressed with Task 1a strict provider normalization and real adapter fixtures. Replaced record-ID heuristics with the reviewer-agreed tagged @Query refresh.
- Pinned environment verified: Xcode 26.4.1 (`17E202`), worktree iPhone 17 UUID `FD1A6EB1-680A-47D4-AFBB-FD710C013B0C`; existing 31 dispatcher tests passed before implementation.

- Implementation review: independent `annotation_code_review` found no serious actionable findings; reviewed provider termination, generator save boundary, bus dedup, tagged query handoff and UI actions.
- Foreground RED: the real-bus text response regression failed with missing progress/save and failure outcome. GREEN: included in the full Chat suite.
- Local package suites: Core 317/317, Chat 1121/1121, Bible 881/881. Provider subtask additionally verified real adapter fixtures in isolation.
- Pinned simulator comparisons: 26 annotation captures, 39 existing Chat captures, and 6 Core Markdown captures passed. Twenty-four annotation baselines intentionally changed; two distinct partial/interrupted captures added. Inventory: 538 → 540 package captures; 579 → 581 including unchanged native previews.
- Both `Super` and `SuperBible` built successfully with Xcode 26.4.1 on the registered iPhone 17 simulator. Changed-file SwiftLint passed with existing warnings only; `git diff --check` passed.
- Manual SuperBible DEBUG QA: chapter, verse and whole-book annotations streamed and saved; regeneration stayed in the same reading surface; close during streaming/reopen retained the result; Copy matched the saved Markdown; Hebrews 4:15 citation navigated correctly. The simulator database contained the three expected annotations and zero Chat conversations. No composer/reference selector appeared in the annotation sheet.
- Integration adjustment: the DEBUG annotate model advertises a 32K context window so Chat's existing compact-model policy does not remove its annotation tool; this preserves the in-chat debug tool-loop while tools-empty foreground requests stream text.
- Core's icon is named `ResponseSparkIcon` with `Chat.SparkIcon` as its compatibility alias to avoid the existing `Core.Core` enum shadowing the module name. Existing Chat image comparisons remained unchanged.
