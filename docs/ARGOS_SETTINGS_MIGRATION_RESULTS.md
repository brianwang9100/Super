# Settings Argos migration results

This tranche replaces 14 legacy Settings captures with native previews. It extends the existing required Argos workflow without changing app behavior, renderer implementation, authentication, or branch protection.

## Coverage

The [Settings inventory](../Scripts/PreviewPilot/settings-inventory.json) maps every new preview to its retired PNG and exact dimensions. All 14 captures are 402×874 points / 1206×2622 pixels. They cover root light/dark, about, compaction, personalization, verbosity, tools light/dark, search on light/dark/off light, and data idle light/dark/failed light. These retain navigation chrome, representative pane layouts, preference states, tool configuration, and an export error without multiplying every state across themes.

Argos increases from 23 to 37 captures. Tracked legacy PNGs decrease from 598 to 584; Settings decreases from 90 to 76. Twelve complete legacy test methods and the light assertion in `dataPaneFailed` are removed with their 14 images. The dark failure assertion keeps its original method name. Behavioral suites and all four legacy package CI jobs remain.

Independent visual review inspected each native/legacy pair: no missing content, new clipping, wrong theme/selected state, or incorrect close/back header was found. The native renderer positions content approximately 14pt lower, renders slider thumbs that Point-Free omitted, and differs in color/glass/capsule details. This is coverage equivalence, not pixel parity with Point-Free.

## Deferred cases

The initial candidate set contained 18 Settings captures. Two complete runs exposed four unstable cases, so they remain entirely in the legacy suite:

- `settings_appearance_light`, `settings_appearance_dark`, and `settings_appearance_haptics_light`: low-bit variation in 16-bit native PNGs. After 8-bit RGBA decoding, dark was identical; the two light captures had one pixel differing by one channel level. We did not weaken the repeatability gate or normalize the renderer output to accept this.
- `settings_data_exporting_light`: the progress indicator changes animation phase.

A follow-up must establish deterministic rendering before migrating these cases. Tall-dark appearance, XXL, model/provider forms, narration, search-off-dark, and other unmigrated Settings scenarios also remain covered by their existing tests.

## Local validation — 2026-09-07

Used Xcode 26.4.1 / 17E202, iOS 26.4.1 / 23E254a, and the registered iPhone 17 simulator. The machine's default Xcode had changed to 27 beta; commands selected `/Applications/Xcode 26.app/Contents/Developer` through `DEVELOPER_DIR` without changing the global selection.

- Two final `npm test` runs each passed 20 Python guards and 42 iOS capture/layout tests, exported exactly 37 images with valid identity/dimensions, and decoded every PNG.
- `repeatability.py` reports 37/37 byte-identical PNGs. All 23 established composer/UIKit captures also match their previous validated outputs byte-for-byte.
- Chat `swift test`: 1,117 tests in 86 suites passed on the pinned toolchain.
- Remaining `SettingsSheetSnapshotTests` on the registered simulator: 73 tests passed, preserving 76 legacy PNGs.
- Both Super and SuperBible Release builds passed; `audit_release.py` found no preview fixtures or vendor renderer in either app. Only DEBUG-guarded fixture declarations changed during the subsequent scope reduction.
- `actionlint .github/workflows/argos.yml` and `git diff --check` passed. Full-repository actionlint reports an existing SC2046 warning in the unchanged TestFlight workflow; this tranche does not edit workflow YAML.

Local ignored evidence: `.build/PreviewPilot/run-b0br4m9z/`, `.build/PreviewPilot/run-m4dz1yjg/`, `.build/argos-settings-final-repeatability.json`, `.build/argos-settings-chat-stable-tests.log`, `.build/argos-settings-legacy-tests.log`, and `.build/argos-settings-release-audit.json`. Generated captures remain ignored in `screenshots/`.

## Delivery gates

The draft PR must produce an Argos build with these 14 additions and the previous 23 unchanged, with no unexplained removals or changes. Inspect the CI images before approving the new baseline. Require passing applicable CI and explicit Codex approval of the current revision before enabling guarded auto-merge. Main continues to require `argos`, `native-previews`, `build`, `lint`, `gitleaks`, `ios-test`, and `swift-test`. The prior required-check enforcement controls are recorded in [PR #332](https://github.com/brianwang9100/Super/pull/332#issuecomment-5571855771).

Git history is unchanged. Its cleanup remains a separately coordinated operation after migration.
