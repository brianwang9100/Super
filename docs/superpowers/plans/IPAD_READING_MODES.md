# iPad Reading Modes — Design and Delivery Plan

> **For agentic workers:** Use `superpowers:executing-plans` to implement the approved design in the delivery slices below. Complete the repository's plan review, implementation review, validation, and PR workflow for each slice.

**Status:** Implemented on 2026-09-12, including the user's [controls and reuse revision](IPAD_READER_CONTROLS_REVISION.md), which supersedes the original delivery slices where they differ. Validation evidence and remaining manual checks are recorded in [IPAD_READING_MODES_VALIDATION.md](IPAD_READING_MODES_VALIDATION.md). Book mode is one continuous paginated Bible, shown as a two-page spread where space permits, with no vertical scrolling. Chapters can span many pages, and each chapter starts on a fresh page. Keep PR #374 draft and auto-merge disabled per the user.

**Goal:** Use the iPad window for larger scripture and three reading modes, with the original native verse-action sheet and low narration controls, while preserving the established iPhone experience.

**Architecture:** Bible owns reading modes, text, selection, and study state. The shared shell owns the active Chat conversation, optional companion layout, and optional applet navigation slot beside the hamburger layer. Core carries generic host-layout and navigation-slot contracts; Bible and Chat never import one another. Bible supplies its existing navigation view and callbacks so the shell can center it across the full window. One primary reading cursor, a stable text locator for paginated reading, and one live Chat session survive layout changes. Compare configures the existing chapter reader and verse renderer; Study uses the same reader and Chat.

**Tech stack:** SwiftUI, existing Core/Bible/Chat packages, GRDB/GRDBQuery, bundled Bible text, Swift Testing, and the repository's simulator/snapshot tooling. No new dependency or provider is needed.

**Design basis:** Product contract below; implementation investigation used the tree delivered in PR #372 (`7b2bc390`, merged as `320d1abf`). Start implementation from current main and check for intervening changes. Relevant rules: [root instructions](../../../AGENTS.md), [shell instructions](../../../App/Shell/AGENTS.md), [Bible instructions](../../../Packages/Bible/AGENTS.md), [architecture](../../MOBILE_ARCHITECTURE.md), [testing](../../TESTING.md), and [visual policy](../../VISUAL_TESTING_POLICY.md).

## Product contract

### Full-width reading and larger text

- Remove the reader's fixed 760-point ceiling on iPad. The workspace uses the available window width, with normal outer margins and a gutter when showing two columns. Each reader fills its assigned column. This does not require widening Chats, Bookmarks, or the standalone Chat overlay.
- Start with a **24-point iPad scripture base**, compared with the current 19-point base, subject to simulator spot checks. Keep iPhone at its current base. Larger scripture includes sensible verse-number, chapter-title, paragraph, and line spacing.
- Apply the app font slider and OS Dynamic Type through `SuperTypography` exactly once. Do not change the shared `readingBodySize` constant, which could affect other content; introduce Bible-specific layout metrics instead.
- Put one current-mode icon immediately to the right of the book/translation button in the navigation bar. Each tap cycles **Book → Compare → Study → Book**; VoiceOver announces the current mode and the next action. This replaces the separate segmented mode selector per the user's execution feedback. Mode changes retain the primary chapter, translation, selected verse context where still visible, and nearest visible verse.
- These are exactly three iPad modes. Narrow iPad Book mode shows one page at a time; Compare and Study have their own compact adaptations. iPhone retains its existing reader.

### Mode behavior

| Mode | Left | Right | Scroll and navigation |
| --- | --- | --- | --- |
| Book | Current page | The immediately following page in the same translation | Text flows left to right, then to the next spread. Horizontal page turns; no vertical scrolling. Every new chapter starts on a fresh page. |
| Compare | Primary chapter and translation | Same chapter in a second translation | One vertical scroll view; matching verse numbers share a row and both cells use the taller cell's height. |
| Study | Primary chapter | The current Chat conversation, fully expanded inside its pane | Reader and transcript scroll independently; composer stays at the bottom of Chat. |

**Book details:** Treat the Bible as one ordered stream of pages. A long chapter may fill the left page, the right page, and further spreads. There is no chapter-height constraint and no independent scrolling inside either page. Preserve paragraphs, poetry, verse numbers, highlights, notes, and annotation controls through page breaks.

- Turn the spread with horizontal swipes or labeled Previous Pages/Next Pages controls; compact Book turns one page at a time. Keep chapter picking and browser Back/Forward separate from page turning. Page turns update the saved reading locator without adding one history entry per page. User paging across a chapter boundary records that chapter visit once so the persisted history cursor and primary chapter remain consistent; restore/reflow never adds a visit. Save chapter, locator, and history envelope together.
- Every chapter begins at the top of the **next available page**, leaving the previous page's remaining space blank. It may begin on the left or right; a chapter break does not force an empty facing page or require a new spread. Cross canonical book boundaries through `BibleBookCatalog`. After the last page, show an end state, never wrap to Genesis or duplicate content to fill the partner page.
- An explicit chapter selection opens that chapter's first page on the left and establishes a new spread origin. Pair subsequent consecutive pages relative to that origin; Previous/Next round trips retain the pairing. Persist the origin as a source locator, not a page index, and retain pairing during single-page adaptation. Rebase to a locally equivalent paired origin as the cache advances so a distant initial chapter does not require unbounded loading. After repagination, map both origin and current locator into the new page sequence, then show the spread containing the current location. A verse/deep-link jump opens the page containing that verse, retaining its source translation and selection. The top chapter indicator follows the leading page; each page identifies its chapter so a chapter transition within a spread is clear.
- Split long verses across pages at rendered line boundaries. Keep verse identity and source ranges across fragments; never require an entire verse or paragraph to fit one page. Keep a section/chapter heading with its first text line when space allows. Do not repeat a verse number or trailing study glyph simply because a page changes.
- A selection spanning a page break still refers to canonical verses, not page-local indexes. Selection is limited to one chapter and translation; selecting a verse in another chapter replaces it, so two different verse 1s cannot be combined. Pending actions keep their captured source even when later paging changes visible selection. Both visible pages may be actionable; actions capture their actual chapter/translation. Narration turns to the page containing the spoken source when follow-reading is active, and manual paging suspends automatic following until the user taps a visible **Resume following** action in the narration bar. Within a verse that spans pages, follow the narrated word/range when available; without that timing, follow once to the verse's first fragment and allow manual paging without repeated jumps.
- Expose each visible verse fragment as an accessible element, including a page that begins mid-verse. Announce its canonical verse and visible continuation text, and retain verse actions without repeating a printed verse number. Do not inherit the current per-paragraph rule that hides every word after the first when that first word is on another page.
- Pagination depends on page width/height, typography, translation, text, and layout-affecting decorations. Font, window, and orientation changes recompute pages while preserving a locator containing book/chapter/verse plus an intra-verse source offset. Page numbers are layout-specific and must not be the durable saved position. Entering Compare/Study uses the locator's chapter/verse; returning to Book restores the precise text location when the source is unchanged.
- Keep a stable page viewport when the low action/narration bar opens or closes by reserving a shared bottom-control band for that layout. This prevents a selected verse moving to another page simply because its actions appear. Actual viewport/font changes reflow around the selected/reading anchor; only one column is shown when two readable pages cannot fit. If even a single rendered line cannot fit with essential controls, keep the location and show a resize-window state instead of clipping text or looping without progress.
- Paginate the current chapter plus bounded neighboring pages/chapters on demand. Use cancellable generation IDs and a bounded cache keyed by text/layout identity; discard stale results during resize or rapid navigation. Do not lay out the whole Bible or compute a fixed total page count before showing text. Start with a simple horizontal transition respecting Reduce Motion; a page-curl animation is outside the initial scope.


**Compare details:** Start with the current translation on the left; use WEB on the right unless the primary is WEB, in which case use KJV. Remember the chosen second translation. Use the bundled KJV, WEB, ASV, and BSB catalog only. Each verse starts a new row, both texts align at the top, and long verses wrap independently within that row. The next verse starts below the taller text. This is structural alignment, without red/green word-difference highlighting in the initial release.

Build rows from the numerically ordered union of actual verse numbers, not array offsets. Coalesce repeated fragments of the same verse in reading order while preserving poetry line breaks; do not change the existing `coalescedVerses()` helper used by tools and annotation grounding. Keep translation-specific headings within their own cell before the associated verse; trailing headings remain visible after the last row. A verse absent from one translation has an explicit empty-state label on that side. Unavailable/corrupt chapter text is a load error with retry, not an empty list of missing verses. The alignment does not attempt semantic reconciliation of different versification systems.

The right picker excludes the left translation. If a primary-translation change would duplicate the right side, move the previous primary translation to the right. Selecting a verse records its source translation for Copy, Share, narration, annotations, and Chat references. Visual emphasis may mark the matching row on both sides, but actions must never silently quote the other translation. Selection is limited to one source column at a time.

**Study details:** Default to an even split. Reuse `ChatScreen` at full progress and the shell's existing `ChatScreenViewModel`; render only one composer and one conversation host. The full-progress Chat pane must not dim, intercept, or disable the reader through the overlay's existing global expanded-state rules. Keep conversation switching, New Chat, drafts, streaming, tools, model controls, and errors functional. Mode changes and window resizing must not send a message, reset a draft, create a conversation, or cancel a response.

Add to Chat attaches the selected source reference to the existing composer without auto-sending. New Chat preserves the current conversation before opening a fresh one in the right pane. Explicit Bible-reference navigation from Chat updates the left pane while keeping the conversation visible; other applet references and existing preview flows keep their normal routing. Opening an unrelated applet exits the split presentation without losing the saved Bible mode or conversation.

### Compact windows and iPhone

- Resolve layout from usable window width and text size, not orientation or `UIScreen` dimensions. Proposed starting fit rules: 24-point outer margins, 24-point gutter, minimum 360-point scripture columns, and minimum 380-point Chat pane. Increase minimum widths when scaled text requires it; verify final thresholds on device.
- Book becomes a single paginated page with page-turn controls, still without vertical scrolling. Compare stacks the two translations inside each verse row, keeping a single scroll and its alignment identity. Study falls back to the existing reader/Chat overlay presentation.
- Retain the requested mode separately from the effective layout so widening the window restores the user's mode. Do not save compact fallback as a different preference.
- Preserve iPhone typography, orientation policy, Chat overlay behavior, and native action/narration sheets. The new mode selector and iPad-specific typography/panels are enabled through a SuperBible capability supplied at the composition root. SuperOS retains its current behavior unless explicitly opted in.
- Restore position using chapter/verse anchors rather than raw pixel offsets when widths, fonts, mode, or keyboard change. Book adds an intra-verse source offset so a verse spanning pages does not jump back to its beginning after reflow.

### Native verse actions and low narration

The user reverted flattened verse actions: retain the original native `.sheet`, action grid, ShareLink, and presentation lifecycle on both devices. Only narration uses a nonmodal reader accessory attached to the iPad reader's bottom safe area, occupying the scripture workspace in Book/Compare and the left pane in Study. iPhone and deeper forms continue to use native `.sheet`.

- Verse actions: reuse the original citation/close header, palette, and action grid with all existing operations and captured source context. Scrolling readers retain their native-sheet selection clearance; Book retains its stable page viewport.
- Narration: citation, previous/play-pause/next, stop, voice, speed, and close arranged horizontally where they fit. Aim for roughly 100–140 points at default size. Voice selection, setup, and detailed errors can open normal secondary sheets; playback/preparing/error states remain visible and actionable.
- Heights are targets, not hard caps. Wrap or allow scrolling at accessibility sizes; keep every control reachable with at least a 44-point hit target. Do not shrink text to force a low profile.
- Keep one shared selection/narration presentation coordinator so they replace one another without overlapping. Preserve dismissal-versus-stop semantics. Freeze narration's source chapter, translation, and verse sequence when playback starts; later selection must not retarget audio. A mode/width change retains that source and playback, even if its page is temporarily hidden; only matching content follows playback. Book changes pages, while Compare/Study use their scrolling behavior. The transport keeps showing the actual narrated citation. Explicit chapter-picker/history/translation navigation or leaving the applet retains the current stop policy. Natural Book page advancement uses a separate cursor-update path that does not invoke the existing navigation routine's blanket narration stop or discard captured study intents; only matching visible source fragments receive emphasis. Moving a page from right to left never creates another narration owner or changes the captured source.
- Measure the actual bar height and reserve it in reader layout. Replace the current fixed 280/360-point first-paint assumptions for the docked path. Compare/Study lift an occluded selection once and follow the active verse by scrolling. Book uses its stable bottom-control band and page/locator rules; no vertical selection-scroll behavior applies. Closing a bar does not jump back.
- In Book/Compare, opening a study bar first minimizes semi-expanded Chat, then replaces the minimized Chat pill and composer accessory flanks in the same bottom control region. Dismissing it restores the pill/accessories without automatically reopening Chat. Add to Chat/New Chat dismisses the bar through the handoff coordinator before presenting the destination Chat. The shell must receive explicit bottom-control occupancy: a reader-local safe-area inset cannot reposition its sibling Chat/accessory layers.
- In Study, bars clear the left pane and never span the Chat composer. With a docked software keyboard, stay above the actual occluded region; a floating keyboard must not reserve its bounding rectangle across the entire window. Reducing height must not hide the last verse or final controls.

The remaining low-bar requirements apply to narration only. Native selection and inline narration have distinct coordinator identities so an outgoing action-sheet callback cannot dismiss incoming narration or advance a queued handoff early.

## State ownership and implementation boundaries

| Owner | Responsibility |
| --- | --- |
| Bible | `BibleReadingMode`, primary reading cursor/history, pagination and page/source locators, comparison translation, per-source selection, verse alignment, narration and study actions, reading preferences. |
| Core | Target-neutral companion request/effective-state contract and owner-keyed optional navigation slot; no Bible enum or database dependency. |
| Shared shell | Resolve companion availability; place opaque applet content, its optional full-window navigation, and one Chat host; route reference/open-conversation actions appropriately for the effective layout. |
| SuperBible bootstrap | Opt Bible into the new workspace capability. Shared shell never imports Bible or checks bundle IDs. |
| Chat | Existing conversation runtime, draft, stream, transcript, composer, and pane-specific chrome/keyboard behavior. |

Canonical highlights, notes, and annotation targets remain translation-independent, matching their existing schema and query keys. Both visible translations reflect the same canonical decorations. Capture source translation and selection in immutable delayed action intents and quotation/annotation context, including disclaimer acceptance and regeneration; do not mutate the primary translation merely to act on the secondary column.

Keep only one writer for the persisted primary position. Book pages are fragments of one paginated reading session, not two chapter view models or two full `BibleScreen` instances. Comparison uses a secondary text load without another persisted cursor. Refactor only the rendering/selection/lifecycle seams needed for pages and columns. Decorations continue through GRDBQuery for each visible chapter, including a spread crossing a chapter boundary.

Use a dedicated Bible-owned preferences record/repository with an explicit migration for mode and secondary translation. Keep the existing primary position/history as the canonical navigation owner. Add a versioned, optional Book text locator with an explicit migration; existing installs start at their saved chapter/verse. Validate locator offsets against the current translation/text and fall back to the referenced verse or chapter start on invalid data. Layout page indexes stay ephemeral. Preferences restore before defaults can overwrite them; corrupt/unknown values fall back safely. Layout capability stays transient. Do not synchronize presentation by having either applet inspect another applet's database.

Keep the primary model, study coordinator, and Chat model above layout branches. `BibleScreen.onDisappear` currently stops narration and dismisses its sheet; distinguish an actual applet exit from a mode/layout transition so rehosting is not mistaken for leaving the reader. Transient active source context must include book, chapter, translation, and verse IDs, not verse number alone. Keep Chat host identity stable too: `ChatScreen.task` invokes `load()`, and the current load path clears interrupted-response state. Retaining only the model is insufficient if layout switching remounts its loader. If stable hosting cannot cover a transition, make the existing initialization/reattachment path idempotent without clearing unsaved terminal/interrupted content.

`BibleStudyPresentationViewModel` coordinates nested actions through native bottom-sheet callbacks and a distinct inline-narration visibility adapter. Opening Annotate/Add Note or Chat captures its source before clearing selection and advances after the outgoing presentation dismisses. Share retains the native ShareLink. Resize during a pending handoff must not strand or duplicate the destination.

## Delivery slices

### 1. Responsive reading metrics and compact reader controls

**Modify:** `BibleChapterReader.swift`, `BibleChapterReaderLayout.swift`, `BibleReadingMetrics.swift`, `BibleParagraphBlock.swift`, `BibleScreen.swift`, `BibleNavBar.swift`, `BibleActionSheet.swift`, `NarrationTransportSheet.swift`, `BibleBottomOverlayKind.swift`, and `BibleStudySheetsModifier.swift` under `Packages/Bible/Sources/Bible/UI/`.

**Also modify:** `BibleApplet.swift` and the SuperBible bootstrap to inject the default-off reading capability; `BibleStudyPresentationViewModel.swift` for bar visibility/handoff completion; a target-neutral bottom-control occupancy contract in Core and its handling in `AppShell.swift`. This coordination is needed before the companion-pane slice, because the existing Chat dock is a sibling of the reader.

**Create:** `BibleReadingLayout.swift` and `BibleStudyBar.swift` in the same UI directory. Add focused layout tests in `Packages/Bible/Tests/BibleTests/UI/BibleReadingLayoutTests.swift`; reuse existing reading metrics, action-sheet, narration, and reader snapshot suites.

- Add failing layout tests for wide iPad filling available width, 19-point compact typography remaining unchanged, 24-point proposed iPad typography, and measured bottom occlusion. Check 375/744/834/1024/1376-point windows and maximum app font scale.
- Thread a Bible-specific reading layout/typography input to paragraph rendering; do not alter Core's shared typography defaults or global content-width constant.
- Separate action/transport contents from their native sheet modifiers. Host them as the approved bottom accessories on capable iPad, retaining existing sheet wrappers for iPhone.
- Test native-sheet and inline-bar handoffs to Annotate/Add Note/Chat, including resize during a pending dismissal, repeated commands, and Chat initially minimized or semi-expanded. Capture source context before clearing selection; advance each handoff exactly once.
- Check initial short-window presentation, resizing while controls are open, source selection, bottom verse reachability, voice-picker return, Share cancellation, narration retry, and dismissal semantics. Verify Book/Compare bars replace and restore the Chat pill/accessories without overlapping hit targets.
- Review intentional iPad images; compare existing iPhone baselines. Build both app targets. This slice can ship before multiple-column content.

### 2. Reading-mode state and paginated Book layout

This is a pagination subsystem, not a second scrollable chapter. Complete a focused rendering/pagination prototype and its acceptance checks before integrating the mode into the shell.

**Create under Bible:** `Models/BibleReadingMode.swift`, `Models/BibleReadingPreferencesRecord.swift`, the preferences repository/protocol, `Models/BibleTextLocator.swift`, `Models/BiblePage.swift`, `Formatting/BiblePaginator.swift`, `ViewModels/BibleReadingWorkspaceViewModel.swift`, `UI/BibleBookPage.swift`, and `UI/BibleBookSpread.swift`.

**Modify:** `BibleDatabase.swift`, `BibleReadingPositionRecord.swift` and its repository, `BibleApplet.swift`, `BibleScreenViewModel.swift`, `BibleScreen.swift`, and targeted token/flow-layout seams. Investigate sharing the existing `VerseTokenizer`/`VerseFlowLayout` measurement with pagination so measurement, visible rendering, verse hit targets, and typography agree. Do not change existing iPhone layout output as a side effect of extraction.

**Tests:** pure pagination/source-range tests, renderer geometry tests, workspace/persistence tests, and representative Book page/spread snapshots.

- Prototype finite-height pagination using actual scaled text and decoration measurements. Exercise a chapter longer than four pages, a verse spanning pages, poetry, section headings, a chapter boundary within a spread, and the final Bible page. Verify no skipped/duplicated source ranges, no cropped lines, and no vertical scrolling.
- Define stable source locators and immutable page fragments. Test exact-fit/overflow lines, over-wide words, empty/unavailable chapters, headings near page bottoms, partial verses, and a viewport too small for one line. Every pagination step must consume text or return an explicit terminal/unavailable result.
- Introduce mode/translation preferences and the versioned optional reading locator. Test migration from the current saved chapter, source-offset validation, restore ordering, and the single persistence writer. Within-chapter page turns update location without history entries; user paging across chapters records one chapter visit with an atomic cursor/history/locator save. Test crossing → relaunch → Back/Forward and ensure restore/reflow does not record visits. Explicit chapter jumps preserve existing history semantics.
- Assemble consecutive page fragments into two-page spreads or one compact page. Test next/previous spread, explicit chapter opening on the left, verse-reference jumps, chapter breaks on either side, canonical book boundaries, and beginning/end clamping. Verify spread-origin pairing through jump → Previous → Next, relaunch, and two-page → one-page → two-page adaptation. Keep page-turn controls distinct from chapter controls.
- Add bounded on-demand pagination/cache with invalidation for viewport, font metrics, translation, text and layout-affecting study decorations. Discard stale generation results. Preserve the visible/selected locator across reflow and avoid whole-Bible pre-pagination.
- Render existing verse interactions on fragments: highlights/selection span page boundaries, source quotation uses canonical verse text, and trailing annotation/note glyphs appear once. Query decorations for all visible chapter identities without creating another primary cursor.
- Integrate the stable lower control band, page-turn narration following, manual-follow suspension, VoiceOver page order/actions including mid-verse continuation elements, keyboard/accessibility page turns, the visible Resume following control, and Reduce Motion. Test opening/closing bars does not shuffle page breaks; actual resize reflows without losing the selected word.
- Expose Book in the mode control once functional. Compare/Study remain hidden until their slices are functional. Record only reviewed intentional Book captures and compare existing iPhone output.

### 3. Verse-aligned translation comparison

**Create under Bible:** `Models/BibleComparisonRow.swift`, `Formatting/BibleComparisonAssembler.swift`, and `UI/BibleTranslationComparison.swift`. Integrate secondary loading/state through `BibleReadingWorkspaceViewModel` and existing text loaders/selectors.

**Tests:** `Formatting/BibleComparisonAssemblerTests.swift`, workspace view-model tests, and representative reader/comparison captures in existing screen suites.

- Write pure alignment tests before rendering: verse A missing on one side, repeated fragments, paragraph boundaries within a verse, poetry, headings before/trailing verses, unequal text lengths, and two empty inputs. Verify the input chapters remain unchanged.
- Distinguish absent chapter/load failure from a successfully loaded chapter with absent verse numbers. Test unavailable/error/retry presentation and cancellation/stale results when rapidly changing either translation.
- Build stable verse-keyed rows from both chapters. Render a single scroll view of top-aligned two-cell rows; each row's natural height is the taller cell. Avoid synchronizing two pixel-offset scroll views.
- Add sticky translation labels/pickers, deterministic distinct-translation behavior, stacked narrow rows, source-aware actions, and narration highlighting of the matched row.
- Verify reference text, copied/shared content, highlight persistence, annotations, and reading anchors use the selected source. Exercise right-column annotation through disclaimer acceptance and regeneration after changing primary selection/translation; the original action must keep its captured source. Preserve paragraph/poetry semantics in paginated Book and the scrolling Study reader.

### 4. Reader plus expanded Chat

**Create:** a generic companion-layout contract under `Packages/Core/Sources/Core/Applet/`, pure host-layout policy tests in Core, and `App/Shell/AppletWorkspace.swift` for shell composition if extraction is needed.

**Modify:** `AppShell.swift`, `AppShellDependencies.swift`, the SuperBible bootstrap, Bible's mode-to-host request bridge, and `Packages/Chat/Sources/Chat/UI/ChatScreen.swift` only where pane chrome needs a distinct presentation input. The existing `ChatOverlay.swift` remains the compact/standalone host. List any new shared app files in both `Super` and `SuperBible` source lists in `project.yml`.

- Define and test generic single-surface/companion requests and effective layout outcomes. Default unsupported applets/targets to existing behavior; do not put Bible mode names in Core.
- Compose the reader left and a single full-progress ChatScreen right using the existing shell-owned model/focus. Separate companion presentation from overlay progress so the reader stays interactive at full Chat expansion.
- Test active stream, draft, selected model, conversation identity, reference attachments, and unsaved interrupted responses across Book/Compare/Study and compact/wide transitions. Mount exactly one composer/observer path. Prove `ChatScreen.task` does not reload/clear the interrupted response on rehosting, or make reattachment nondestructive and test that path.
- Route Add to Chat/New Chat and explicit Bible-reference navigation while preserving split layout. Keep native previews and unrelated applet navigation working.
- Verify docked/floating/hardware keyboards, drag/scroll gestures, pane-safe action bars, microphone/narration arbitration, Settings, and conversation switching. Do not cancel narration simply because a layout branch changed.
- Build both targets and confirm SuperOS and iPhone retain their prior presentation policy.

### 5. Integration and release checks

- Implement the approved mode preference/default and ensure layout thresholds account for both app scaling and OS Dynamic Type. Verify relaunch, unsupported/corrupt preference values, and small-window restoration.
- Run `swift test` in every affected package; run UIKit comparison/behavior suites serially on the registered worktree simulator. Use canned Chat only. Build SuperBible and Super with the pinned environment in `simulator-pins.json`.
- Test iPad portrait/landscape, mini-sized windows, 375 × 486 resizing, 100%/120% app font scale, large Dynamic Type, and real VoiceOver focus order. Recheck iPhone reader, keyboard, selection, narration, and Chat morphs.
- Reuse the current eight iPad captures where they represent the same risks; explicitly replace superseded width expectations. Add captures only for distinct risks: Book continuation/chapter-break spreads and a compact page, comparison with uneven/missing verses, stacked comparison, Study with Chat, and low controls/large-text reflow. Final capture-count delta is computed from the approved fixture list against current main; never auto-record or relax tolerances.
- Have an independent reviewer check implementation and interaction ownership. Deliver each slice through the repository PR template, local results, screenshots, CI, and current-revision Codex approval before protected merge.

## Acceptance criteria

1. The iPad reader uses its allotted screen width and larger text; iPhone default rendering stays unchanged.
2. Book is one continuous paginated Bible, with two facing pages where space permits and one page in compact iPad windows. Long chapters span pages without vertical scrolling; each chapter starts on the next fresh page. Page turns and repagination preserve source location without skipped/duplicated text or multiple saved-position writers.
3. Comparison aligns matching verse numbers at every row boundary regardless of wrapping or omissions, including after resizing.
4. Study keeps scripture usable beside a fully functional current conversation. Mode switching preserves draft/stream/session and source context.
5. Verse actions retain their original native sheet. Narration stays low in the reader region, clears the visible text/composer, and remains accessible at large type. Navigation stays centered across the full iPad window in every mode.
6. Mode/translation preferences restore predictably, and compact adaptation never destroys the user's requested mode.

## Decisions for product review

- **Book behavior — confirmed:** continuous page flow, potentially many pages per chapter, no vertical scrolling, and a page break at every chapter. The proposed chapter-break rule uses the next available page (left or right), without forcing a new spread; explicit chapter selection opens on the left.
- **iPad control presentation — revised by user:** original native verse actions, inline narration, and shell-hosted navigation centered across the full window. Secondary forms and all iPhone sheets retain native presentation.
- **Initial geometry:** proposed 24-point scripture and even column split, without a draggable divider or word-level translation diff in the first release. Tune through iPad spot checks before recording final baselines.

## Plan review

An independent reviewer identified shell dock/bar overlap, native-sheet callback assumptions in inline handoffs, canonical decoration identity versus source translation, narration source lifetime, and Chat reload behavior on rehosting. The plan now explicitly covers each in state ownership, the first delivery slice, and companion-mode validation.

The Book-mode clarification replaces the earlier next-chapter pairing with true finite-height pagination. Its slice now covers source-range continuity, chapter page breaks, stable location persistence, typography/viewport reflow, decoration layout, narration page following, and one-page compact adaptation.

Pagination review additionally specified chapter-crossing history consistency, one-chapter selection, accessible continuation fragments, source-based spread origins, and a visible Resume following action. These are included in the Book contract and validation tasks.
