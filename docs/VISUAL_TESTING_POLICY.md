# Visual testing policy and migration audit

Updated 2026-09-07 against commit `00693278`. The policy below applies to new work. The shortlist is a proposed migration inventory, not an implemented test deletion: all existing legacy PNGs and their current CI checks remain in place. Main subsequently added 14 baseline images (557 total after the merge); the historical counts and shortlist below remain tied to the audited commit, and those new regression cases are not retirement candidates.

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

Counts are tracked PNG files under `Packages/**/__Snapshots__/`, not Swift test function counts. Parameterized tests can own multiple images. Database/text snapshots are excluded.

| Package | UI suite files | PNGs | Current PNG size |
| --- | ---: | ---: | ---: |
| Chat | 26 | 272 | 28.91 MiB |
| Bible | 25 | 209 | 33.10 MiB |
| Todo | 9 | 42 | 3.56 MiB |
| Core | 3 | 20 | 1.24 MiB |
| Total | 63 | 543 | 66.81 MiB |

The current Argos pilot additionally renders 21 composer scenarios and two UIKit renderer/font probes. Its 23 generated PNGs are ignored and are not part of the 543 tracked baselines.

A SHA-256 comparison found 21 byte-identical pairs. Examples:

- Settings root, tools, appearance, search-on, and idle-data XXL images match their default-size partners. The Settings suite explicitly describes several XXL cases as fixed-chrome sentinels. Consolidate those sentinels after proving typography behavior with focused assertions and representative captures.
- Annotation generating-empty and generating-over-populated images match in both the sheet and container suites. The state-precedence behavior still needs an assertion even if only one visual loading fixture remains.
- Settings disabled-Apple and custom-provider images match. Verify the fallback behavior before removing either input case.
- Todo filter, empty screen, and two editor large-font-scale images match their default-size partners. The filter test explicitly injects `superFontScale(1.5)`, so these are fixture/scaling audit items, not safe automatic deletions.

## First migration shortlist: 179 images to 102

These four suites account for one third of the current images. Keep the following existing scenarios as the initial migration selection, subject to the retirement criteria below. Other scenarios are retirement candidates; the retained light/dark, typography, loading/error, and known-regression owners must be confirmed in the replacement renders. This first pass would reduce the repository-wide inventory from 543 to 466 (77 fewer, 14.2%) before any gallery consolidation. It does not claim a corresponding percentage reduction in CI time.

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

1. Finish the OIDC upload and validate Argos comparison/rejection/approval, failed capture/upload, and missing-image handling. Establish and review a main-branch reference and require the actual Argos review check before removing legacy visual enforcement.
2. Migrate the selected scenarios package by package. Keep a tracked expected-name inventory; fail on missing, duplicate, or unexpected captures. Xcode development previews do not automatically become CI captures. Validate repeatability and intentional-diff detection on the pinned toolchain.
3. For each retired test, record its visual replacement or behavioral assertion. Review proposed removals as coverage changes. Correct ineffective fixtures rather than silently dropping the risk they were meant to cover.
4. Remove the pilot's baseline-hash and Point-Free image-parity dependency before deleting its composer PNGs. Keep capture identity, font registration, environment, dimensions, and image-integrity checks independently.
5. Remove migrated legacy visual assertions and their PNGs together. Preserve nonvisual assertions in mixed suites. Update CI discovery and the `ios-test` aggregation contract in the same change so migrated/empty directories neither fail discovery nor produce a false green. Preserve UIKit-only behavioral tests and app build checks.
6. Measure a shared native capture job versus package shards: one job can save repeated boot/build overhead; shards can shorten wall time at the cost of more runners. Choose from measured critical-path and runner-minute results. Keep changes to test execution separate from baseline approval.
7. Once migrated, use Xcode previews and targeted local capture for iteration; CI owns the full visual comparison. A full local render is optional unless debugging rendering or changing capture infrastructure. Local unit, integration, and database tests remain required for code changes.

## Generated files and historical Git storage

Argos stores visual builds and compares them against a reference build; our tests still generate the images. See the [Argos any-framework guide](https://argos-ci.com/docs/quickstart/any-test-framework.md). Source fixtures and capture inventories remain in Git; generated output belongs in ignored `screenshots/`, which is already configured. Retain Point-Free PNGs while their tests or parity tooling use them. Do not ignore every `__Snapshots__/` folder: non-image snapshots remain useful and tracked.

Deleting migrated PNGs in a normal commit stops future image churn but does not remove their previous versions. `.gitignore` does not change this. A read-only audit of all local refs found 5,031 historical PNG blobs under package snapshot paths: 823.39 MiB uncompressed and approximately 577.67 MiB in their current Git storage representation. The shared Git object store reports 1.30 GiB of packs plus 80.39 MiB of loose objects. These totals include other branches/worktrees, and delta/shared-object storage means the snapshot figure is not an exact reclaimable-size estimate or a measurement of GitHub's repository size.

The least disruptive first step is to stop committing migrated images. New developer clones can use Git's partial clone (`--filter=blob:none`) to defer downloading historical blobs. The Argos workflow currently uses full history for baseline/commit discovery; do not reduce its fetch depth without validating that behavior.

To reclaim historical image space, use a separately approved maintenance operation after active PRs are merged or paused:

1. Back up the original repository and make a fresh disposable clone. Do not rewrite the shared object store used by active worktrees.
2. Inventory every historical image path, including renamed/moved folders. Use `git filter-repo --analyze` and preview a PNG-only removal with `git filter-repo`. Preserve text/schema snapshots, source fixtures, and application image assets. A blanket `__Snapshots__` deletion is too broad.
3. Verify the rewritten repository, retained files, branch/tag mapping, tests at the new tip, and fresh-clone size. Old commits that depended on removed image baselines will no longer run their original visual tests; preserve an offline archive if that reproducibility matters.
4. Review the measured savings and exact affected branches/tags before authorizing force pushes. Coordinate branch protections, open PRs, signed commits/tags, clones, and worktrees: rewritten commits have new hashes. Re-clone or explicitly migrate outstanding work; merging an old branch can restore the removed history.
5. Re-establish Argos's main reference after the rewrite because commit identities changed. Old local clones, reflogs, forks, and GitHub PR refs may keep old objects alive. GitHub Support does not purge non-sensitive files on request, so do not promise that a force push immediately frees all GitHub-side storage.

[GitHub's large-file guidance](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github) recommends `git filter-repo` for old files; its [history-rewrite documentation](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository) explains the changed hashes, collaboration impact, and retained-ref limitations. No history rewrite, garbage collection, force push, or worktree cleanup is part of this audit.
