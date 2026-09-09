# Repository snapshot testing

The reviewed PNGs in Git are the visual baselines. The inventory is **625 images: 584 package snapshots (Bible 276, Chat 246, Core 20, Todo 42) and 41 native previews**. Default local and CI commands compare against these baselines. Missing or changed images fail; CI never records replacements. Keep the fixture coverage and renderer choices described in [VISUAL_TESTING_POLICY.md](VISUAL_TESTING_POLICY.md).

## Run comparisons

Use macOS, Python 3, XcodeGen, and the exact Xcode/device/runtime builds in [simulator-pins.json](../Scripts/VisualTesting/simulator-pins.json). Follow [TESTING.md](TESTING.md#simulator-environment) for environment setup and the dedicated per-worktree simulator. Both drivers obtain that simulator through `Scripts/worktree_simulator.py ensure`.

```sh
python3 -m pip install -r Scripts/VisualTesting/requirements.txt
python3 Scripts/VisualTesting/run.py
python3 Scripts/VisualTesting/capture.py Chat --output .build/chat-visual-capture
python3 Scripts/PreviewPilot/run.py
python3 Scripts/PreviewPilot/run.py --output .build/native-visual-capture
```

The first driver compares and validates the complete inventory. `npm test` remains an optional convenience alias; no npm dependencies or Argos CLI installation are needed. The package command compares and exports one package to a fresh output directory; substitute Bible, Core, or Todo as needed. Native commands compare all 41 previews, with optional export to a fresh output directory. `--output` never disables comparison. Direct simulator package tests also compare baselines; use the driver when a validated capture bundle is needed.

Package bundles contain `images/` and `capture.json`; package logs and result bundles stay under `.build/VisualTesting/`, and native evidence under `.build/PreviewPilot/`. Inspect expected, actual, and diff artifacts when comparison fails. Inventory validation checks exact identities, dimensions, PNG decoding, hashes, and run identity, and rejects missing, duplicate, unexpected, corrupt, or wrong-sized images. A successful subset is local evidence, not a replacement for complete CI checks.

## Review intentional baseline changes

Package baselines are tracked at `Packages/<Package>/Tests/<TestTarget>/UI/Snapshots/__Snapshots__/<Suite>/<testName>.<captureName>.png`. Native baselines are tracked in `Scripts/PreviewPilot/__Snapshots__/`. Scratch captures and comparison artifacts remain ignored.

1. Run the default comparison and inspect failures on the pinned renderer. Fix unintended UI or fixture changes first.
2. For intentional output, add `--record` to the relevant local package or native command. Recording is explicit and unavailable in CI; never auto-record missing or changed baselines to make a check green.
3. Inspect the recorded PNGs and their diff, then rerun without `--record` to prove comparison passes. Include the PNGs and fixture changes in the PR for review.
4. Report the visual reason, affected tests, local results, and before/after inventory count in **Test Coverage**. Each additional capture needs a distinct risk not already covered by a screen or gallery.

Package snapshots retain their existing Point-Free image strategies and tolerances through test-only `VisualTestSupport`. Native snapshots compare decoded RGBA pixels, allowing only RGB differences of one channel level on at most 0.01% of pixels per image; alpha must match exactly. This bounded rounding tolerance covers independently verified local-versus-hosted rendering noise (167 pixels across 20 images), and accepted rounding is reported with evidence. Do not widen tolerances to hide failures; renderer differences require inspected evidence and review.

Each UIKit suite remains serialized, registers fonts, and preserves its existing traits, sizes, and behavioral assertions. Native previews retain the 21 composer scenarios, 18 Settings panes, and two UIKit probes. The native renderer preserves standard 8-bit color and a fixed host-layer clock for the real spinner. Its earlier output differed from Point-Free Settings rendering; restoring Git storage does not undo those renderer fixes or promise parity with the retired Settings images.

## Add a package snapshot

Add the Swift fixture, explicitly record its reviewed baseline, and register the image in [package-inventory.json](../Scripts/VisualTesting/package-inventory.json). For example:

```json
{
  "package": "Todo",
  "suite": "TodoScreenSnapshotTests",
  "testName": "populatedLight",
  "captureName": "populated_light",
  "image": "Todo_TodoScreenSnapshotTests_populatedLight.populated_light.png",
  "pixels": [1206, 2622]
}
```

`suite` is the Swift filename stem. `testName` and `captureName` are the exporter-sanitized `testName` and `named` arguments: replace runs of non-word characters with `-` and trim edge dashes (for example, `populatedLight()` becomes `populatedLight`). Explicit components use ASCII letters, digits, underscores, and internal dashes. The image identity must match exactly; dimensions are decoded pixels. Omit `legacy` and `variant` for new captures; existing rows retain their historical mappings. Parameterized visual states require distinct stable names. Document the risk and count change, then run the complete comparison.

## CI and retirement history

[snapshots.yml](../.github/workflows/snapshots.yml) retains package `ios-test` and `native-previews` gates and comparison evidence on failure. Baseline approval happens through reviewed PNG commits. There is no upload or external visual approval step. The [CI documentation](CI_PIPELINE.md#repository-snapshot-workflow) defines the separately validated live removal of the old `argos` required check; YAML alone cannot change repository protection. All other required checks and protections remain enforced.

The [pilot results](PREVIEW_VISUAL_TESTING_RESULTS.md), [Settings migration](ARGOS_SETTINGS_MIGRATION_RESULTS.md), [Settings stability](ARGOS_SETTINGS_STABILITY_RESULTS.md), and [complete migration results](ARGOS_COMPLETE_MIGRATION_RESULTS.md) are historical renderer and migration evidence. The rollback preserves the current UI and all 623 captures. Git history cleanup and its monitor remain paused; there is no history rewrite or deletion of recovery evidence.
