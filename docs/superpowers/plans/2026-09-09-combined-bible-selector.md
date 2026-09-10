# Combined Bible selector implementation plan

**Goal:** Implement the approved interactive design: one content-hugging glass selector showing book/chapter above a smaller translation subtitle, opening one native sheet with Book & chapter / Translation segments and one Read action.

**Design:** The approved conversation prototype is the specification. Preserve the existing history controls, book search (including verse ranges), ordering, bookmarks, notes, annotation actions, and deferred sheet handoffs. Draft choices survive tab changes and apply together only on Read; closing discards them. Short names use their intrinsic width; normal long names stay in the primary row. Accessibility sizes may use the existing second-row fallback rather than clip controls.

**Architecture:** Keep book filtering in `BibleBookSheetViewModel`. A new `BibleSelectionSheetViewModel` owns one presentation's book-picker model, selected tab, draft position/translation, and optional verse range. `BibleScreenViewModel.selectionSheet` is the sole picker presentation state. Commit through its existing bounded reference application logic so chapter, translation, history, selection and persistence change together. Existing book/translation views support embedded content, preserving their independent visual fixtures.

**Stack and constraints:** Swift 6, SwiftUI, Observation, existing GRDB queries. Use SuperTypography for both font-scale axes, SuperGlass for all glass, BibleSheetMotion for transitions, and native `.sheet`. No dependencies, database changes, applet boundary changes, or unrelated refactors. Work only in this worktree. Use the dedicated simulator and pinned Xcode 26.4.1 / iOS 26.4.1 builds.

**Plan review:** No serious gaps. Added explicit coverage that a plain chapter clears staged verse bounds while changing translation preserves them.

## 1. Draft state and atomic application

- [x] Add `BibleSelectionSheetViewModelTests.swift` with draft isolation, cancellation/reopening, independent tab/search state, valid chapter changes, verse-range search, and atomic commit/persistence tests. The regression is an accidental navigation or intermediate persisted chapter/translation when merely choosing a draft.
- [x] Add `BibleSelectionSheetViewModel.swift`: `bookPicker`, `tab`, `position`, `translation`, and optional `verseRange: ClosedRange<Int>`. Validate chapter ranges against the injected catalog. Store verse bounds without enumerating a potentially huge range.
- [x] Replace the separate root presentation states with `selectionSheet`, `presentSelectionSheet()`, `dismissSelectionSheet()`, and `applySelection()`. Apply by bounded membership checks against loaded chapter verses, reusing `applyReference(position:translation:selectsVerse:)`. Set the explicit translation intent, respect restoration guards, and persist one final tuple.
- [x] Keep direct `selectChapter`/`selectTranslation` APIs for existing callers. Update picker presentation assertions and study/sidebar dismissal tests to the single sheet. Preserve history semantics: a translation-only commit retains the forward branch, a chapter change creates one visit.
- [x] Run the focused new tests before and after implementation, then the affected existing navigation and sheet handoff tests.

## 2. Combined SwiftUI sheet

- [x] Add `BibleSelectionSheet.swift` with the centered Bible header, glass segments, book and translation content, and a glass Read footer identifying the pending passage and translation. Give each interactive control an accessible label/selected state.
- [x] Add embedded presentation options to `BibleBookSheet` and `BibleTranslationSheet`, keeping existing standalone fixtures unchanged. Retain the book pane's identity while changing tabs, dismiss search focus when leaving it, and retain its query, expansion and scroll position.
- [x] Use the draft position to highlight chapter cells and stage search results instead of navigating immediately. Preserve reactive decoration queries and note/annotation callbacks. These explicit study actions dismiss and use the existing deferred handoff coordinator, discarding pending reading changes.
- [x] Wire one `.sheet(item:)` in `BibleScreen`, and remove the separate translation presentation modifier. Read applies the staged choices; close and interactive dismissal discard them.

## 3. Content-hugging reader selector

- [x] Update `BibleNavigationSelector` to one passage button, stacked book/chapter and translation, alongside the existing history pair. Remove the standalone translation segment/divider/chevron and callback.
- [x] Retain intrinsic sizing for normal content, enough tap height, and a bounded accessibility fallback. Keep the label fully available to VoiceOver. The parent centers the intrinsic group rather than expanding its glass across available width.
- [x] Reuse `BibleNavBarSnapshotTests.historyStatesGallery` to cover short and long book names alongside history states; retain the existing narrow accessibility capture. Add meaningful hosting-size assertions that a short label is narrower than a long one and ordinary Corinthians/Thessalonians fit the primary row.

## 4. Validation and delivery

- [x] Run the complete Bible `swift test` suite with the pinned toolchain.
- [x] Add four unified-sheet captures: primary book tab light/dark, translation tab light, and a large-text reflow case. Existing book/translation component captures retain search/decorations and row coverage. Register these in `package-inventory.json`; expected total 586 → 590 (+4).
- [x] Run affected simulator comparisons first; inspect differences before explicitly recording intentional changes. Inspect new/changed PNGs and rerun comparison. Reader/nav baselines reflect the shared selector; book-picker baselines also reflect intrinsic ordering-label sizing.
- [x] Build and manually verify SuperBible on the worktree simulator: long titles, content hugging, search/verse jumps, switch tabs, Read/cancel, history, and book note/annotation handoff. Verify SuperOS's distinct chapter-arrow layout as well.
- [x] Obtain a separate change review, address findings, and repeat affected validation.
- [ ] Open a draft PR using the repository template, including test results, screenshot count/rationale, and reviewed screenshots. Monitor CI and Codex review together every ten minutes. After explicit approval of the current revision and passing required CI, mark ready, enable auto-merge without bypassing checks, and verify merge. Disable auto-merge before any additional push.

## Risks

- A draft translation must not mutate narration, reader selection, or persistence before Read.
- Sheet tab changes must not discard query/scroll state or leave a hidden keyboard active.
- Existing book note/annotation presentation relies on the picker's native dismissal completion.
- Accessibility layout must preserve both font-scale axes and keep history controls reachable; content hugging must not force oversized text outside available width.
- Snapshot glass is a deterministic fallback; inspect real native glass in the running app.

## QA results

- Complete Bible package suite: 946 tests in 96 suites passed.
- Native iPhone 17 / iOS 26.4.1 checks passed in SuperBible and SuperOS: compact toolbar, Corinthians/Thessalonians, draft tab/search retention, atomic Read, back/forward, verse-range selection, cancel, and deferred book-note presentation.
- Both app targets build with Xcode 26.4.1.
- Independent implementation review found no remaining serious issues. Large-text inspection also corrected the snapshot typography injection and retained readable book counts/order controls.
- Inspected and explicitly recorded 57 existing PNG updates and four new combined-sheet captures; recording validates the complete 259-image Bible inventory. Capture discovery and 48 visual infrastructure guard tests pass.
- Final non-recording simulator comparison passed all 259 Bible captures.

## Integration with current main

Merged main’s sparse-comment cleanup, undo/redo history icons, and closed-actions contract for deep-link navigation. The combined selector retains these changes. Independent review found no serious merge regressions; all 946 Bible tests pass. Updated the range-commit assertion to keep actions closed while preserving the selected verses and pending scroll.
- Both integrated app targets build. The affected toolbar/reader snapshot suites pass after explicit recording of the reviewed history glyph changes. The Mac locked before a final live-app repeat; pre-merge native flows passed, and integrated behavior has automated coverage.
- Final integrated non-recording comparison passed all 259 Bible captures.
