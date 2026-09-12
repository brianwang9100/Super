# iPad Reading Modes — Validation

Implementation follows [the approved plan](IPAD_READING_MODES.md). The final control is one icon immediately after the passage/translation selector, cycling Book → Compare → Study → Book. The capability is enabled only by SuperBible on iPad; iPhone and SuperOS retain their existing presentation.

## Automated checks

Pinned local environment: Xcode 26.4.1, iOS 26.4.1, registered worktree iPhone 17 simulator. All image comparisons below ran with recording disabled after intentional recordings were inspected.

| Check | Result |
| --- | --- |
| Bible package | 998 tests, 103 suites passed after final mode-control change |
| Core package | 342 tests, 45 suites passed |
| Chat package | 1,144 tests, 87 suites passed |
| Bible UIKit | 86 tests across reader, navigation, chapter reader, actions, narration, and reading-mode suites passed |
| Chat UIKit | 27 tests across ChatScreen and ChatOverlay suites passed |
| SuperBible and Super simulator builds | Passed; final icon revision rebuilt before publication |
| SwiftLint | Repository lint passed with its existing warnings |
| Capture inventory and whitespace | Discovery and `git diff --check` passed |

The new tests exercise source-specific selection/copy/highlights/annotations, disclaimer and regeneration context, captured narration replay, reading preference persistence and retry, single-writer cursor/history persistence, finite pagination and continuation ranges, chapter/book boundaries, bounded cache replenishment, decoration invalidation during in-flight pagination, supplementary heading/glyph anchors, restore/reflow, compact/wide pairing, and companion layout policy. Existing Chat reload tests now retain interrupted output, draft, model, and scroll state.

Independent plan and implementation reviews completed. Six actionable implementation findings were reproduced or covered by targeted regressions and resolved; the follow-up review and the subsequent cycling-icon review were clean.

## Visual coverage

Inventory changes from **601 to 609 captures (+8)**: Book continuation in light/dark, compact chapter opening, aligned comparison with missing verses/unequal text/headings/poetry, stacked comparison at 120% app scale, two inline-control galleries including Dynamic Type XXL, and one narrow light/dark cycling-icon gallery.

Two existing iPad-size BibleScreen baselines were also refreshed. Main's navigation-height change (#373) updated its 30 reader captures but omitted the landscape and narrow-window fixtures added by #372. Inspection confirmed the differences were the already-merged 44-point toolbar. Existing iPhone PNG baselines remain unchanged. No tolerances or capture coverage were relaxed.

## Simulator interaction checks

The worktree's retained iPad simulator was checked in landscape and portrait. Book displays consecutive finite pages and keeps its page breaks when verse actions open or close. Compare shows the first verse below its labels, aligns rows, and captures the right translation for actions. Study keeps the reader interactive beside Chat and confines its verse actions to the reader pane.

A typed draft survived Book/Compare/Study transitions. A WEB verse selected in Compare was attached as WEB to the existing draft while the primary reader remained KJV. A canned response continued while Book was displayed and returned intact in Study. No provider request was needed. Accessibility inspection confirmed mode labels and canonical verse labels on page-continuation fragments.

The Mac locked during the final software-keyboard spot check. Docked/floating software keyboards, physical-device behavior, and live VoiceOver gesture order remain manual follow-up checks; they are not claimed as verified. Narrow layouts, app font scaling, and large type have automated layout and image coverage. A physical iPad spot check remains useful for these input-specific cases.

## Delivery

One integrated PR contains the shared source state, pagination, comparison, companion layout, and reader controls. CI and current-revision Codex approval are required before ready/auto-merge; protected checks must remain enforced.
