# Complete the Argos visual migration

## Objective and scope

Finish migrating every remaining Git-backed visual PNG comparison to Argos. Preserve behavioral/database/text snapshots and meaningful visual regression coverage. Start from merged PR #337 (41 native previews, 580 remaining legacy PNGs); recount current main before changes. Do not rewrite Git history.

## Approach

The first 41 native previews remain unchanged. For the remaining package suites, reuse the existing deterministic Swift test fixtures and Point-Free image rendering strategies, but replace `verifySnapshot` image comparisons with a shared capture-only exporter. Point-Free remains a test dependency (also used by database text snapshots), not an app SDK. Argos alone owns image baselines and review. This avoids duplicating complex database/provider/transcript fixtures in app source solely to change baseline storage.

Add a Core-owned test-support library product, consumed only by test targets. Its generic image-export helper preserves existing fixture/layout strategies, generates stable package/suite/test/name identities, requires a writable explicit output folder for capture runs, reports capture/encoding/write/duplicate failures, and never reads or records source-tree baselines. Normal local iOS tests may use an ignored/temporary export folder; macOS nonvisual tests are unchanged. Rendering must remain serial where UIKit requires it.

Track an inventory of every remaining legacy PNG, its original dimensions, stable Argos identity, owning test, and final disposition. Apply the existing risk shortlist only where a retained screenshot or named behavioral test demonstrably covers the removed case. Preserve recent regression additions and uncertain cases rather than deleting to meet a count target. Exact inventory validation must catch missing, extra, duplicate, renamed, malformed, or cropped captures. Every retired PNG requires either a verified equivalent export or a reviewed coverage mapping.

Use one Argos build containing the existing native previews and all package exports. CI may render packages in parallel and upload artifacts, but a final fail-closed aggregate job must validate the complete expected set and upload once with OIDC. Preserve required `native-previews`, `argos`, and `ios-test` identities and the app/package/security/lint gates. Remove the former Git-baseline snapshot comparison jobs only as their capture replacements become active; preserve their nonvisual/UIKit-only test coverage. Fork PRs remain blocked unless their existing authentication restriction is separately resolved.

## Validation and delivery

1. Independent plan review, including exporter failure semantics, fixture reuse, inventory completeness, consolidation evidence, and workflow aggregation.
2. Implement/test the shared exporter and drivers with negative controls for missing/duplicate/invalid images and failed package capture. Prove a small Core tranche before applying to remaining packages. Keep original PNGs until capture fidelity is verified.
3. Migrate package fixtures, audit proposed shortlist consolidations, and run every affected package's macOS tests plus iOS capture suites on the pinned toolchain/registered simulator. Capture twice and inspect differing output plus representative layouts against original baselines. Do not assume existing tolerances imply deterministic Argos results.
4. Verify Release apps exclude test support, renderer, and Argos components. Validate workflow success/failure aggregation and complete screenshot inventory. Delete verified Git PNGs and obsolete record controls; preserve text snapshots and app assets. Add prevention against new tracked visual baselines.
5. Independent final review, draft PR(s) with exact count/coverage evidence, current-revision Codex approval, all CI and inspected Argos baseline approval, then guarded auto-merge and verified merge. Monitor every ten minutes. Continue automatically after each merged tranche until all migration criteria are met.

## Completion criteria

No tracked visual baseline PNGs remain under package snapshot directories; no image comparison depends on local Git baselines; every retained visual risk has a tracked Argos capture or explicit reviewed replacement; CI uploads the complete expected build and blocks on visual review; obsolete legacy comparison workflows/recording guidance are removed; nonvisual tests remain enforced. Git history cleanup remains a separately approved maintenance task.

## Risks

Swift Testing/XCTest bridging and asynchronous image strategies require bounded completion without swallowing errors. Filename collisions and parameterized cases require exact identities. UIKit execution must remain serialized. Existing rendering noise or progress animation may require a capture-specific fix or careful Argos inspection, not blanket tolerance increases. Shared support must never enter app products. Consolidating provider/layout/accessibility cases without evidence would lose coverage. Cross-job artifacts must belong to the same run/revision and missing shards must prevent upload and merge.

## Implementation findings

Core's 20 captures matched the original PNG dimensions and decoded pixels exactly and repeated without changes. The exporter’s off-main completion control initially exposed inherited main-actor isolation; an explicit Sendable callback fixed it and all six failure/control tests passed.

Four Bible selection tests already rendered both open and dismissed action-sheet states against the same legacy image name. Exclusive publication correctly caught these collisions. Preserve both inputs with four explicit `dismissed` variant identities mapped to their actual shared historical PNGs. After three independently verified consolidations, the final inventory is 581 package images plus 41 native previews (622 total). This exposes existing coverage rather than adding four new test scenarios.

Independent review also caught stale local screenshots surviving a guard failure. `npm test` now enters the coordinator first, clears the previous upload folder, and then runs guards; failed guard/native/package controls verify that no stale or partial upload remains.
