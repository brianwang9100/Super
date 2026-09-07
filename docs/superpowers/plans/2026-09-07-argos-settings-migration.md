# Settings pane Argos migration implementation plan

**Goal:** Move 14 repeatable Settings pane captures from Point-Free to the required Argos workflow, retaining all other coverage.

**Architecture:** Extend the existing native preview capture pipeline. Add DEBUG-only `PreviewSettingsPane` fixture and 14 explicit `#Preview` declarations inside Chat; capture them alongside the unchanged composer and UIKit scenarios. Keep a checked-in Settings name/dimension/legacy mapping inventory with no runtime dependency on legacy PNGs after retirement.

**Tech stack:** SwiftUI, Swift 6, native SnapshotPreviews renderer, Argos CLI, Python inventory guards; existing Xcode 26.4.1/17E202, iOS 26.4.1/23E254a, iPhone 17, XcodeGen 2.45.4.

**Spec:** `docs/VISUAL_TESTING_POLICY.md` representative Settings shortlist and incremental-retirement criteria. Existing migration design and user instruction authorize continuation; no product behavior changes.

## Scope and risks

- Migrate root light/dark, about, compaction, personalization, verbosity, tools light/dark, search on light/dark/off light, and data idle light/dark/failed light: 14.
- Defer appearance light/dark/full-height light and data exporting light because repeated native captures varied. Preserve their legacy tests and all four PNGs. Preserve model-detail, model-list, narration setup, busy, font/XXL, tall-dark appearance, search-off-dark, and data-export/failure dark legacy cases. Argos 23→37; legacy 598→584; Settings 90→76 after verified retirement.
- Preserve header close/back behavior by rendering the same SettingsSheet `initialPane` seam inside the same themed neutral container. Preseed view model state before rendering so `.task` cannot clobber fixtures. Keep model/tool sample rows, app info, availability, token limits, theme selection, and export phases identical to the original fixture.
- All 14 migrated captures are 402×874 points (1206×2622 pixels). The deferred full-height appearance capture remains covered by its 402×1340-point legacy fixture and historical haptics filename.
- All new fixtures/stubs are under `#if DEBUG && canImport(UIKit)`; no network, credentials, database, or production composition changes. Pin OS Dynamic Type to Large and derive typography from seeded settings.
- Do not delete shared legacy helpers or the entire Settings suite. Keep both calls and PNGs owned by `dataPaneExporting`. In `dataPaneFailed`, remove only the migrated light call and image, retaining the original method name for the dark filename mapping. Both idle captures migrate, so `dataPaneIdle` can retire.

## Implementation and verification

1. Review this plan independently before implementation.
2. Add `PreviewSettingsPane.swift`, `SettingsPanePreviews.swift`, and `settings-inventory.json`. The fixture uses synchronous preseeded SettingsViewModel and private inert repository/receiver implementations. Each declaration has an explicit stable name and fixed layout:

   ```swift
   #Preview("settings_root_light", traits: .fixedLayout(width: 402, height: 874)) {
       PreviewSettingsPane(pane: .root, theme: .vellumLight)
   }
   ```

3. Extend `PreviewPilotTests.snapshotPreviews()` with the exact Settings source pattern. Generalize `verify.py` across composer and Settings inventories; validate each source declaration set, global duplicate names, group count, dimensions, sidecar identity, and complete exports. Add negative guard cases for a missing Settings capture and incorrect Settings dimensions; existing PNG/decoder/lock/environment controls stay intact. The final inventory and source declarations must exclude the four deferred captures.
4. Run pinned `npm test` twice for the final 37-capture inventory. Compare every output for repeatability; compare the 23 previous images byte-for-byte. Inspect all 14 new images against their named legacy counterparts at matching sizes; record renderer differences and ensure actual pane content and chrome coverage is retained. Keep legacy tests until replacements are verified.
5. Remove only the 14 mapped legacy assertions/PNGs after local verification; preserve the remaining suite and helper behavior. Run Chat's full macOS suite and remaining Settings simulator suite. Add new fixture identifiers to release audit, build both Release app targets, and confirm fixtures/vendor renderer are absent. Run actionlint, Python guards, and diff checks.
6. Update current Argos/testing guidance, migration counts, and concise evidence. Independent change review; address findings and repeat affected checks. Create a draft PR with count rationale and validation results.
7. Review Argos's 14 added captures and unchanged previous 23 against the verified local evidence before approving the new visual baseline. Require all current-revision Codex reviews and CI, preserve seven required checks, then mark ready and enable guarded squash auto-merge. Monitor every ten minutes and verify merge; do not rewrite history or remove the worktree.

## Repeatability evidence and deferred follow-up

The initial 18-case trial exposed low-bit variance in the appearance captures' 16-bit PNG channels, including a light-appearance difference affecting one pixel after conversion to 8-bit. The exporting capture also varied with the spinner's animation phase. These four cases remain under their existing Point-Free assertions; they are excluded from the final native capture inventory instead of weakening comparison or approving unstable baselines.

The remaining 14 Settings cases were stable in the trial comparisons, and all 23 prior Argos images remained byte-identical. Verify the final 37-image inventory after the scope adjustment. Visual inspection of the trial renders confirmed retained content and state coverage, with renderer differences including an approximately 14-point downward placement of Settings header/content. Record these as migration differences, not pixel parity.

A later bounded migration must investigate appearance rendering precision and spinner phase control, demonstrate repeatable full native captures, and review equivalent content before retiring those four legacy cases. Preserve the full-height theme-grid coverage and both exporting themes during that follow-up.

## Plan review

Independent review found no blocking issue with the final 14-case scope: unstable cases retain their existing enforcement, and the remaining replacements preserve their mapped coverage. Settings has 90 tracked PNGs at base `80c57219`; this tranche leaves 76. Preserve persisted theme IDs exactly: among migrated cases, only tools dark seeds `.vellumDark`; root/search/data dark retain the default persisted light theme while receiving a dark visual environment. Preserve partial-method ownership and complete the final-inventory verification above before retirement and merge.
