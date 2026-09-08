# Complete Argos migration

This migration moves all remaining package UI image baselines to Argos while retaining their existing Swift fixtures and Point-Free image rendering strategies. The test-only `VisualTestSupport` product exports images without reading or recording Git baselines. Database/text snapshots and behavioral assertions remain in place. Neither Release app links the visual test support or renderer.

## Coverage and storage

| Owner | Previous Git PNGs | Final Argos package captures | Coverage change |
| --- | ---: | ---: | --- |
| Bible | 272 | 276 | Four existing open/dismissed action states receive distinct identities instead of sharing a filename |
| Chat | 247 | 244 | Two identical automatic-title fixtures and one redundant compaction fixture consolidated |
| Core | 20 | 20 | Preserved |
| Todo | 42 | 42 | Preserved |
| Package total | 581 | 582 | All retained scenarios accounted for |

The existing 41 native captures remain, giving **623 images in one complete Argos build**. The working tree contains zero package UI baseline PNGs. Source fixtures, inventories, and reviewed dependency locks stay tracked; generated images are ignored. This normal commit does not rewrite Git history or reclaim historical objects.

The four Bible variants were already rendered by the previous tests, once before and once after action-sheet dismissal. Exclusive filename creation exposed their shared names. Each variant maps to its genuine original baseline path in [package-inventory.json](../Scripts/VisualTesting/package-inventory.json). The three consolidations have explicit retained visual and behavioral coverage in [retired-coverage.json](../Scripts/VisualTesting/retired-coverage.json). No other historical shortlist removals were assumed safe.

## Capture fidelity before main sync

Before incorporating main PR #338, the first complete local set passed exact inventory, dimensions, PNG decoding, and five-shard aggregation checks on Xcode 26.4.1 / 17E202, iOS 26.4.1 / 23E254a, and the registered iPhone 17 simulator.

Across all 581 package exports, **568 match every decoded RGBA byte of their mapped originals**: Bible 276, Core 20, Todo 42, and Chat 230. The remaining 13 Chat captures were individually inspected:

- Twelve ChatScreen/ChatOverlay images predate the existing composer padding change in [PR #276](https://github.com/brianwang9100/Super/pull/276), commit `b756ac87`. The current images reflect the existing 16pt outer inset: 2pt inward from the old expanded inset and 4pt from the old minimized inset. Text, controls, wrapping, and states remain intact. These are stale baseline corrections, not a new product layout change in this migration.
- The dark Settings exporting image differs only in spinner shading.

The final pre-sync full `npm test` command passed and all **622/622 PNGs are byte-for-byte identical** to the first complete set (also checked across all decoded RGBA channels). A separate repeat of all 92 images in the affected ChatOverlay, ChatScreen, and SettingsSheet suites was exact across every RGBA byte. Core's 20 captures also repeated exactly. Comparisons include all four channels; they do not rely on an alpha-only bounding box or a low average error to infer equivalence.

Local evidence is retained under `.build/VisualTesting/validation-first/`, `.build/VisualTesting/first-complete/`, and `.build/argos-full-*-fidelity.json`. Generated evidence is intentionally not committed. The full repeat report is `.build/argos-full-repeat-fidelity.json`. CI/Argos review remains a delivery gate.

## Main sync: PR #338

Main PR #338 (`79b70606`) adds the existing Chat `focusedTurn` fixture at **1206×2100 pixels** and updates 14 image references. The migration incorporates that fixture and the updated current-main references while retaining the merged Chat changes. Chat now has 247 former Git PNGs and 244 exported captures after the same three consolidations. With Bible’s four explicit existing-state variants, the package total is 581 former PNGs → 582 captures; the 41 native captures are unchanged, giving 623 images.

Post-sync validation passed: all 244 Chat exports have the expected dimensions and inventory; 231 match current-main RGBA bytes exactly, including the new focused-turn image and all 14 updated references. The same 13 previously inspected differences remain, and each matches the pre-sync capture exactly. Chat macOS tests passed (1,101 tests / 82 suites). All 25 visual suites passed, along with the 12-test stationary-response suite and nine related focus, pulse, and overlay hierarchy tests. The stationary-response suite is now selected by the CI capture driver. All 23 pipeline guards pass, including a regression control requiring that suite. Evidence is retained under `.build/argos-main-sync-*`. The 622-image repeat above remains pre-sync evidence; CI validates the complete updated 623-image revision.

## Verification and failure controls before main sync

| Check | Local result |
| --- | --- |
| Core macOS tests | 320 tests / 40 suites passed |
| Bible macOS tests | 822 tests / 82 suites passed |
| Chat macOS tests | 1,117 tests / 86 suites passed |
| Todo macOS tests | 84 tests / 11 suites passed |
| Core iOS selected suites | 26 tests passed, including six exporter controls |
| Bible iOS selected suites | 206 tests passed across all 26 existing suites |
| Chat iOS selected suites | 231 tests passed across all 25 existing suites |
| Todo iOS selected suites | 42 tests passed across all nine existing suites |
| Native capture guards | 22 tests passed |
| Package/pipeline/local migration guards | 22 tests passed |
| Simulator lifecycle and hook guards | 29 tests passed |
| Release builds and binary audit | Super and SuperBible passed; no visual support/renderer artifacts or symbols |
| CI lint command, actionlint, diff whitespace | Passed |

All 63 pre-existing package UI suites remain selected. Parameterized assertions such as icon asset loading and nonvisual assertions inside visual suites remain enforced. The Core exporter controls exercise encoding/write errors, duplicate identities, timeout/late callbacks, duplicate callbacks, and off-main completion. The latter initially exposed inherited actor isolation; an explicit Sendable callback fixed the crash.

Pipeline controls reject missing/extra/duplicate/corrupt/wrong-sized images, zero-test selections, failed suites, stale revisions/attempts, changed artifact contents, and incomplete shard sets. Artifacts stay separate until validation, so download flattening cannot silently overwrite duplicate names. A review finding about stale local uploads is fixed: `npm test` removes the previous upload folder before running guards; guard/native/package failures cannot leave old or partial screenshots available for upload.

## CI and delivery

The Argos workflow renders native/Bible/Chat/Core/Todo shards on the same workflow invocation, including documentation-only PRs. Package suites execute one at a time on their registered simulator; CI runs packages independently. Both renderers consume committed dependency resolutions and shared toolchain pins. Only the complete aggregate uploads with OIDC.

The old Git-image comparison jobs are removed from the iOS build workflow. Required contexts remain `argos` (Argos App 57576), plus `native-previews`, `ios-test`, `build`, `lint`, `gitleaks`, and `swift-test` (GitHub Actions App 15368). Live branch protection was read and verified during this migration; its settings were not weakened. Current-revision Codex approval, applicable CI, inspected Argos approval, and verified merge are still required by the delivery workflow.
