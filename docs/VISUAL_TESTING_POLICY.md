# Visual testing policy and migration audit

The current capture inventory contains **623 images: 582 package captures and 41 native previews**. Repository PNGs are the image baseline store. Package fixtures retain their Point-Free rendering and comparison strategies through test-only `VisualTestSupport`; native previews compare pixels exactly. The four package CI jobs and native shard remain, with missing or changed baselines failing local and CI runs. Intentional baseline changes are reviewed PNG commits; scratch captures and diffs are ignored. See [snapshot testing](SNAPSHOT_TESTING.md) and the [required-check cutover](CI_PIPELINE.md#repository-snapshot-workflow).

The audit tables below describe commit `00693278` (543 images), not the current inventory. A later tracked-file count at `58d18b5b` found 619 PNGs; composer and Settings migrations reduced that to 580 while establishing 41 native captures. Main PR #338 (`79b70606`) then added the existing `focusedTurn` Chat fixture, bringing the pre-migration tree to 581 PNGs. Those 581 filenames represent 585 rendered states: four `BibleScreenSnapshotTests` fixtures already rendered both `dismissActions = false` and `true` under the same filename. Capture validation exposed the collisions. The migration keeps the original IDs for the open-action state and gives the four dismissed-action variants distinct IDs, then consolidates only the three cases listed below: 585 − 3 = 582 package captures. This preserves existing scenario coverage rather than adding four new test scenarios. The broader historical shortlist remains a proposal; it does not authorize matrix deletion. See [Settings stability results](ARGOS_SETTINGS_STABILITY_RESULTS.md) for historical native renderer verification.

The current package inventory is Bible 276, Chat 244, Core 20, and Todo 42, plus 41 native previews. The four explicit Bible variant IDs account for Bible’s filename count changing from 272 to 276.

## Verified consolidations

| Retired package image case | Retained visual evidence | Retained behavioral evidence |
| --- | --- | --- |
| `SettingsSheetSnapshotTests.modelsPaneTitlingAutomatic` | `modelsPaneWithAFMAvailable`: identical light image and equivalent automatic-title/default fixture | `ChatSettingsTests.titleSettingsDefaults` and `titleModelIdClearsToAutomatic` |
| `SettingsSheetSnapshotTests.modelsPaneTitlingAutomaticDark` | `modelsPaneWithAFMAvailableDark`: identical dark image and equivalent automatic-title/default fixture | The same title-default and reset-to-automatic tests |
| `MessageListSnapshotTests.compactionBanner` | `compactionBannerWithMarkdown`: same banner placement between the same message roles, with richer summary rendering | `ChatScreenViewModelProjectionTests.compactionBannerInsertion` checks cutoff placement and summary |

These are the only three consolidations in the complete migration. Keep all other fixtures, including newer regression cases, uncertain duplicate-looking states, fixed-chrome XXL sentinels, and distinct minimum-scale/dark reader risks. Existing source fixtures now compare repository baselines; database/text snapshots and nonvisual assertions remain intact.

## Select coverage by risk

Visual tests protect layout, typography, contrast, clipping, layering, and rendering regressions. Unit and integration tests protect data permutations, provider selection, state transitions, action availability, persistence, and navigation decisions. A changed SwiftUI file does not automatically require another screenshot.

- Start with the smallest existing screen or gallery that visibly exercises the change. A component below the captured viewport is not covered merely because its parent is in the image.
- Keep representative primary layouts in Vellum light and dark. Additional states normally need one theme; add a second where color or contrast changes independently. Keep the existing eight-theme Chat and Bible galleries as the palette owners.
- Preserve meaningful empty, loading, error, and populated layouts without repeating every state in every theme. A label/value permutation alone usually needs an assertion, not a full-screen capture.
- Keep an XXL reflow case for each distinct text-heavy layout, representative app font-scale extremes, Reduce Motion where the rendered state differs, and each distinct applet-level form-factor layout. These axes are independent; test their combinations only when an interaction is a known risk.
- Keep known visual regression cases, including long transcript bottom anchoring, malformed streaming Markdown, keyboard/composer geometry, and Bible underline/highlight behavior at minimum scale. A count target is not a reason to drop them.
- Combine small related controls into a readable, bounded gallery where possible. Do not create one enormous image with offscreen content or replace a screen's positioning coverage with isolated controls.
- For each new screenshot, the PR's Test Coverage section must name its visual risk, explain why existing coverage misses it, and report the before/after capture count. No automatic matrix expansion. The count is a review signal, not a hard quota that hides legitimate new coverage.
- Before retiring a case, name the retained visual case or behavioral test that covers its purpose. Identical images alone do not establish equivalent coverage. Investigate whether a fixture actually applies the environment or reaches the intended state.

## Measured inventory

The historical counts below are tracked PNG files under `Packages/**/__Snapshots__/`, not Swift test function counts. Parameterized tests can own multiple images. Database/text snapshots are excluded.

| Package | UI suite files | PNGs | Current PNG size |
| --- | ---: | ---: | ---: |
| Chat | 26 | 272 | 28.91 MiB |
| Bible | 25 | 209 | 33.10 MiB |
| Todo | 9 | 42 | 3.56 MiB |
| Core | 3 | 20 | 1.24 MiB |
| Total | 63 | 543 | 66.81 MiB |

The initial Argos pilot additionally rendered 21 composer scenarios and two UIKit renderer/font probes. Its 23 generated PNGs were ignored and were not part of the 543 tracked baselines at that audit revision.

A SHA-256 comparison found 21 byte-identical pairs. Examples:

- Settings root, tools, appearance, search-on, and idle-data XXL images match their default-size partners. The Settings suite explicitly describes several XXL cases as fixed-chrome sentinels. Consolidate those sentinels after proving typography behavior with focused assertions and representative captures.
- Annotation generating-empty and generating-over-populated images match in both the sheet and container suites. The state-precedence behavior still needs an assertion even if only one visual loading fixture remains.
- Settings disabled-Apple and custom-provider images match. Verify the fallback behavior before removing either input case.
- Todo filter, empty screen, and two editor large-font-scale images match their default-size partners. The filter test explicitly injects `superFontScale(1.5)`, so these are fixture/scaling audit items, not safe automatic deletions.

## First migration shortlist: 179 images to 102

At the audit commit, these four suites accounted for one third of the images. Keep the following existing scenarios as the initial migration selection, subject to the retirement criteria below. Other scenarios are retirement candidates; the retained light/dark, typography, loading/error, and known-regression owners must be confirmed in the replacement renders. This first pass would reduce the repository-wide inventory from 543 to 466 (77 fewer, 14.2%) before any gallery consolidation. It does not claim a corresponding percentage reduction in CI time.

| Suite | Current | Selected | Selection approach |
| --- | ---: | ---: | --- |
| Chat `SettingsSheetSnapshotTests` | 85 | 42 | Keep distinct pane/form structures and failure layouts; reduce provider, title-setting, and repeated XXL matrices. |
| Bible `BibleScreenSnapshotTests` | 39 | 24 | Keep reader layouts and scale-sensitive regression cases; use one theme for secondary state/size combinations. |
| Chat `MessageListSnapshotTests` | 31 | 20 | Keep rich content, incomplete streaming syntax, errors, scale extremes, and bottom anchoring. |
| Bible `BibleBookSheetSnapshotTests` | 24 | 16 | Keep search/jump layouts, scrolling anchors, and decoration states; avoid repeating every result in dark and XXL. |
| Total | 179 | 102 | Retire only with replacement evidence. |

Names below are existing test method names. The four `settings_data_*` entries select a specific named PNG because those methods produce light and dark captures.

### Settings: 42

```text
rootLight rootDark
appearancePane appearancePaneDark appearancePaneHapticsLight
aboutPane compactionPane personalizationPane verbosityPane
settings_data_idle_light settings_data_idle_dark
settings_data_exporting_light settings_data_failed_light
modelsPopulated modelsPaneAsModalRoot modelsPaneAsModalRootDark
toolsPane toolsPaneDark
searchPaneOnLight searchPaneOnDark searchPaneOffLight
modelDetailProviderCustom modelDetailProviderCustomDark modelDetailProviderCustomXXL
modelDetailProviderOpenAI modelDetailProviderApple
modelDetailEdit modelDetailEditOffCatalogModel
modelDetailProviderOpenAIModelsLoading modelDetailModelListFallbackNote
modelDetailProviderContextWindowError modelDetailProviderOpenAIUnlockedXXL
modelsPaneWithAFMAvailable modelsPaneWithAFMModelNotReady
modelsPaneWithAFMAppleIntelligenceNotEnabled modelsPaneWithAFMDeviceNotEligible
modelDetailAppleFoundation
modelsPaneTitlingExplicitModel modelsPaneTitlingOff
modelDetailNativeSearch modelDetailDebugSearch modelsPaneWithDebug
```

Before retiring the other provider captures, verify that provider-specific fields and their visibility are asserted and represented by the retained custom/native/Apple form shapes. Preserve an additional capture if it reveals a distinct layout. The same condition applies to settings states whose content is below the current viewport.

### Bible reader: 24

```text
populatedLight populatedDark populatedLightXXL
populatedFontScaleMaxLight populatedFontScaleMinLight
genesisStart revelationEnd unavailableLight
selectionActiveLight selectionActiveDark selectionActiveLightXXL selectionActiveFontScaleMinLight
highlightedLight highlightedDark highlightedLightXXL highlightedFontScaleMinLight
immersiveLight immersiveLightXXL
annotatedLight annotatedLightXXL
narratingLight narratingLightXXL narratingFontScaleMinLight
chatToastLight
```

Keep behavioral assertions for first/last chapter navigation and selection/narration state changes. The retained minimum-scale cases protect the underline floor and seamless highlight band; do not replace those with a generic populated screen.

### Transcript: 20

```text
populatedLight populatedDark markdownContent dynamicTypeXXLMarkdown codeBlock table
thinkingBlockWithMarkdown thinkingBlockWithMarkdownDark
streamingTail streamingTailMidFence streamingTailMidFenceDark
streamingTailMidBold streamingTailMidInlineCode streamingTailMidListLightXXL
streamingTailThinkingMidFenceLight
errorBannerWithAction compactionBannerWithMarkdown
appearanceScaleMaxXXL appearanceScaleMin freshlyMountedLongTranscriptLight
```

The incomplete Markdown cases exercise different parser/rendering paths; they are not interchangeable. Retain the existing parser and state tests even when reducing the second-theme companions.

### Book picker: 16

```text
expandedLight expandedDark expandedLightXXL
searchLight alphabeticalLight noResultsLight
autoExpandLight chapterDeepLinkLight verseDeepLinkLight verseDeepLinkLightXXL
midListLight longBookLateChapterLight
filledLight generatingLight noteFilledLight bookmarkedLight
```

Keep query/deep-link resolution assertions. `midListLight` and `longBookLateChapterLight` protect different scroll anchoring cases and both stay.

## Next consolidation candidates

These require fixture work, so no numerical savings are claimed yet:

| Existing coverage | Consolidation direction | Evidence required before retirement |
| --- | --- | --- |
| Chat pills: copy confirmation, memory update, source citations, verse references; context meter | A few bounded galleries with short/long labels and collapsed/expanded states | Every distinct control state visible; a focused reflow capture; state/action assertions preserved. |
| Bible glyphs, verse trailers, chapter footer/nav controls | Palette/state gallery plus retained reader decoration and boundary cases | Preserve trailer ordering, disabled controls, selection dot, and positioning in the reader. |
| Annotation sheet/container/block suites | Keep visual layout in the sheet and long-content card; test container projection/state precedence behavior separately | In-memory DB/reactive tests cover the container's mapping and updates; loading/error/populated layouts remain captured. |
| Note list and container suites | One visual owner for empty/populated/long content plus container integration tests | Live DB updates and provenance/footers remain tested. |
| Todo state boxes, headers, filter pills, empty states | A compact control gallery plus screen/editor/filter layouts | Verify font-scale fixtures first; do not treat identical large-scale PNGs as proof of correctness. |
| Chat screen, overlay, composer, header, empty state | Keep integrated positioning plus focused cases only for geometry not visible in the screen | Keyboard, minimized/mid-morph composer, long title, recording/Reduce Motion, and reference pills remain covered. Keep all 21 composer pilot cases during parity validation. |

The existing `DSIconSnapshotTests` two-image catalog is already a good gallery pattern. Keep the 16 Chat/Bible theme-gallery images and the two native renderer/font probes during migration. Database snapshots remain entirely outside this pruning effort.

## CI cost and migration sequence

Measured from [iOS Build run 34063979885](https://github.com/brianwang9100/Super/actions/runs/34063979885), the previous successful PR run at `df941e27`:

| Package | Whole job, excluding queue | Build-and-snapshot step |
| --- | ---: | ---: |
| Bible | 12m 41s | 8m 55s |
| Chat | 11m 27s | 8m 20s |
| Core | 8m 17s | 5m 04s |
| Todo | 8m 17s | 5m 03s |

These four jobs consumed about 41 runner-minutes. Each simulator boot took roughly two minutes. The snapshot step includes compilation/install/test startup, so it is not a per-image rendering benchmark. Runner availability also caused queue delays. Fewer images should reduce capture work and review volume; cold builds, simulator boot, and queue capacity need separate attention.

The repository snapshot pipeline preserves five shards: native, Bible, Chat, Core, and Todo. Package shards retain each scenario's renderer, size, traits, comparison tolerances, and behavioral assertions. Each job compares checked-in baselines and publishes image/manifest evidence. Exact inventory validation rejects missing, unexpected, duplicate, corrupt, or wrong-sized output. `ios-test` preserves the package aggregate contract and `native-previews` requires native and package comparisons and complete combined inventory validation. Missing or failed shards cannot produce a partial green build.

Historical OIDC upload and Argos rejection→approval enforcement were verified in [PR #332](https://github.com/brianwang9100/Super/pull/332#issuecomment-5571855771). Those results describe the retired integration. Current changes require inspected repository diffs, current-revision review, and passing required checks. The historical cost table above does not predict the replacement pipeline's runtime.

Use Xcode previews and targeted local comparison for iteration; CI compares the full inventory on every PR. A full local comparison is required when changing snapshot infrastructure or investigating cross-suite rendering. Local unit, integration, and database tests remain required for code changes. See [local commands](TESTING.md#simulator-environment).

## Generated files and historical Git storage

Checked-in PNG baselines live under package `UI/Snapshots/__Snapshots__/` directories and `Scripts/PreviewPilot/__Snapshots__/`. Record intentional changes explicitly on the pinned local simulator, inspect the image differences, and include them in the reviewed PR. Never record automatically to make a failure pass; CI refuses recording. Capture bundles and diff artifacts belong in ignored build/output directories. Non-image snapshots remain tracked.

The earlier storage audit is historical: a read-only audit of all local refs found 5,031 historical PNG blobs under package snapshot paths, 823.39 MiB uncompressed and approximately 577.67 MiB in their then-current Git storage representation. The shared object store reported 1.30 GiB of packs plus 80.39 MiB of loose objects. These totals included other branches/worktrees; shared and delta storage meant they were not exact reclaimable-size estimates or measurements of GitHub's repository size.

Git history cleanup and its monitor remain paused. The rollback restores repository baselines with ordinary reviewed commits, preserves recovery evidence and current UI, and does not rewrite history, force-push, garbage-collect, or remove worktrees. Historical migration and renderer reports remain evidence of their original revisions, not instructions to delete coverage or active baseline dependencies. See the [rollback plan](superpowers/plans/2026-09-08-repository-snapshot-rollback.md).
