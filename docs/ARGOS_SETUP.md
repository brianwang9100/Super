# Argos visual testing

This project exports package UI fixtures and native iOS `#Preview` scenarios, then uploads the complete 622-image set with the Argos CLI, following the [any-framework quickstart](https://argos-ci.com/docs/quickstart/any-test-framework.md). No Playwright or app runtime SDK is involved.

## Local usage

Prerequisites: macOS, Node 22 or newer, Python 3, Xcode 26.4.1 / 17E202, iOS simulator runtime 26.4.1 / 23E254a, and XcodeGen 2.45.4. Keep only the exact 23E254a build for the iOS-26-4 runtime identifier.

```sh
npm ci --ignore-scripts
python3 -m pip install -r Scripts/VisualTesting/requirements.txt
npm test
# Set ARGOS_TOKEN in your shell environment, then:
npx --no-install argos upload ./screenshots
```

`npm test` runs the capture guards, exports all four package shards (581 images), captures the native shard (41 images), and validates the complete inventory before staging only PNGs in ignored `./screenshots`. Pillow from the checked-in requirements is required for complete image decoding. The pinned environment comes from [simulator-pins.json](../Scripts/VisualTesting/simulator-pins.json), shared by both drivers, the simulator helper, and the local guard.

Both drivers obtain the registered worktree simulator through `Scripts/worktree_simulator.py ensure`; explicit native UUID arguments must match that association. Ownership is recorded in the common Git directory and survives worktree moves. See [simulator lifecycle](TESTING.md#worktree-simulator-lifecycle). If the default developer directory selects Xcode 27, set `DEVELOPER_DIR='/Applications/Xcode 26.app/Contents/Developer'`; the drivers still verify the exact pinned build.

For iteration, `npm run test:visual:native` captures and validates the 41 native previews without staging an upload directory. `python3 Scripts/VisualTesting/capture.py Chat --output .build/chat-visual-capture` exports one package to a fresh bundle directory. Substitute Bible/Core/Todo as needed. These subsets are local evidence; never upload a subset as the full Argos build. Use `npm test` before a manual full upload. Local behavioral, integration, and database tests remain required for code changes.

Package fixtures retain their Point-Free image strategies through test-only `VisualTestSupport`. Each visual suite is serialized and the driver runs one suite at a time with simulator parallel testing disabled. Native capture pins English, United States, left-to-right layout, and Large UIKit text size for the probes. Dependencies are locked in `Scripts/PreviewPilot/Package.resolved` for native previews and `Scripts/VisualTesting/Package.resolved` for package captures; the patched renderer remains pinned by revision and patch hash. Review dependency updates and rerun capture validation before committing them.

Each shard produces `images/` and `capture.json`. Aggregation checks exact identities and dimensions, full PNG decoding, hashes and run/attempt/commit identity. Missing, duplicate, unexpected, or corrupt output prevents upload. Package logs and xcresults stay under `.build/VisualTesting/run-*`; native evidence stays under `.build/PreviewPilot/run-*`. Sidecars never become Argos snapshots. Argos performs image comparison; no local Git PNG baselines are read or recorded.

## GitHub Actions

[`.github/workflows/argos.yml`](../.github/workflows/argos.yml) runs all five capture shards on every same-repository PR, main push, and manual dispatch, including documentation changes. It validates and aggregates their artifacts before one OIDC upload. The four package jobs feed `ios-test`; `native-previews` covers full aggregation and upload. App builds remain in `ios-build.yml`. Capture evidence is retained for seven days, including on failures. The workflow uses `macos-26`, pinned tools, commit-pinned actions, and the exact CLI dependency in `package-lock.json`.

External-fork PRs remain blocked while their upload authentication path is unavailable. A skipped upload does not satisfy the separate required `argos` status; do not bypass it.

CI uploads prefer GitHub OIDC: `id-token: write` lets the CLI obtain a short-lived GitHub-signed identity, which Argos verifies before granting build-scoped upload credentials. GitHub OIDC must also be enabled in the Argos project's authentication settings. `ARGOS_PROJECT` selects the project and read-only `GITHUB_TOKEN` provides PR metadata. Keep `ARGOS_TOKEN` unset, since it takes precedence over OIDC. The previously configured repository secret remains unused; local uploads can still use the user's shell token.

Tokenless is the fallback when OIDC is unavailable: Argos verifies the repository, commit, branch, and in-progress workflow through GitHub's API. The previous tokenless CI upload was rejected because tokenless authentication was not enabled in this Argos project, despite successful capture. Enable that option separately and validate a fork run before removing the workflow job condition. Until that path is verified, fork PRs remain blocked; do not bypass the required status or execute fork code through `pull_request_target`. See [GitHub Actions authentication](https://argos-ci.com/docs/learn/integrations/github-actions-authentication.md).

Main branch protection requires both `argos` (Argos App 57576) and `native-previews` (GitHub Actions 15368), in addition to `build`, `lint`, `gitleaks`, `ios-test`, and `swift-test`. This was applied through GitHub settings on 2026-09-07; YAML alone cannot make a check required. Upload success is insufficient when Argos reports visual changes awaiting approval. Failed or missing capture/upload/review checks prevent normal merging. The existing administrator bypass setting is unchanged; agents must never use it.

The composer retirement merged in [PR #332](https://github.com/brianwang9100/Super/pull/332) at `80c57219`. Its [required-check control evidence](https://github.com/brianwang9100/Super/pull/332#issuecomment-5571855771) records the capture/upload failure controls, unchanged comparison, and visual rejection→approval enforcement. New migrations still require inspected replacement captures, current-revision Codex approval, and passing checks. Only approve intentional, inspected visual changes.

## First build and baseline

The initial capture and upload succeeded on 2026-09-06: [build #1](https://app.argos-ci.com/brianwang9100/Super/builds/1), with 23 added screenshots, 0 changed, and 0 removed. Argos reports `changes-detected`, as expected for the new image set, with no reference build yet. The repository's `ARGOS_TOKEN` Actions secret is configured. Local capture evidence is `.build/PreviewPilot/run-2rccaqq9/`; all original eight guard tests and the 25-case capture/layout test run passed. Review hardening initially added six renderer-integrity and simulator-identity guards (14 total), plus an iOS fixture test for explicit Reduce Motion overrides. Integration with the shared simulator helper replaces the two naming tests with three registered-device selection tests (15 Python guards total). The capture target also includes two UIKit text-size inheritance regressions; both probes fix the size category to Large. A corrupt-image control was rejected before upload.

A local upload uses the current Git branch and commit. Uncommitted fixture/tooling changes are included in the captured images but are not a committed baseline. The first upload from `codex/argos-visual-testing` is an onboarding build. PR #329 landed on `main`; [main capture run 34117546159](https://github.com/brianwang9100/Super/actions/runs/34117546159) succeeded and [build #7](https://app.argos-ci.com/brianwang9100/Super/builds/7) established the reference at `58d18b5b`. Argos reported success with its automatic main-branch approval. This is distinct from a reviewer accepting a PR diff. [Baseline behavior](https://argos-ci.com/docs/quickstart/any-test-framework.md).

The initial baseline contains 23 images: 21 composer scenarios and 2 UIKit probes. Renderer fixes, repeatability evidence, and the one-to-one legacy mapping are documented in [the pilot results](PREVIEW_VISUAL_TESTING_RESULTS.md). Settings now contributes 18 native pane captures. The complete migration also exports 581 package images; new coverage still needs a distinct visual-risk rationale.

## Verified diff demonstration

[Build #2](https://app.argos-ci.com/brianwang9100/Super/builds/2) successfully compared against build #1 on the same branch and commit: **1 changed, 22 unchanged, 0 added, 0 removed**. Only `composer_typed_light` temporarily changed its fixture text from “Hello world” to “Hello Argos”. Argos identified that exact screenshot as changed. The original preview source was restored byte-for-byte after capture; all 23 regenerated local PNGs match build #1 byte-for-byte. During the PR #332 enforcement controls, rejecting this deliberate diff produced a failing GitHub status; approving it then produced success. [Build #8](https://app.argos-ci.com/brianwang9100/Super/builds/8) compared all 23 images unchanged against main build #7. A no-change build remains successful regardless of review disposition, so build #8 alone did not prove rejection enforcement. The temporary GitHub review used for the controls was dismissed. See the [recorded results](https://github.com/brianwang9100/Super/pull/332#issuecomment-5571855771).

For reviewer access, use `env -u ARGOS_TOKEN npx --no-install argos login`, then the same prefix with `argos whoami`, `argos build`, or `argos review`. The upload token otherwise takes precedence over the reviewer login.

## Usage

Each complete run uploads 622 screenshots: 581 package captures and 41 native previews. Count PR updates, retries, and main captures before expanding coverage. Consult [current pricing](https://argos-ci.com/pricing). Open-source sponsorship is conditional and is not assumed by this integration.

## Migration and local workflow

Argos is the sole image baseline store. Source fixtures, capture inventories, and renderer dependencies remain tracked; generated PNGs stay ignored. GRDB and text snapshots remain in Git. The migration exports 581 package cases, preserving their original strategy, traits, dimensions, and behavioral assertions, and retains the 41 native captures. Four existing Bible reader fixtures rendered open and dismissed action states under the same filename; distinct dismissed-state IDs now preserve both outputs. The former 580 filenames represented 584 states, and three verified consolidations leave 581 package captures. These are existing test scenarios, not four newly added scenarios; see [the coverage policy](VISUAL_TESTING_POLICY.md#verified-consolidations).

Native captures include 21 composer scenarios, 18 Settings panes, and two UIKit probes. The native renderer uses standard 8-bit color for window/target rendering and a fixed host-layer clock to capture the real spinner. The historical Settings migration found content approximately 14pt lower and different slider/color/glass details from the old Point-Free rendering; pixel parity was not claimed. Package capture migration retains Point-Free rendering instead of recreating every screen as a native preview.

The [pilot results](PREVIEW_VISUAL_TESTING_RESULTS.md), [initial Settings migration results](ARGOS_SETTINGS_MIGRATION_RESULTS.md), and [Settings stability results](ARGOS_SETTINGS_STABILITY_RESULTS.md) preserve the evidence for those earlier tranches. They are historical reports, not live baseline dependencies or current full-pipeline results. Every current revision still requires inspected Argos changes and passing required checks.

The [complete migration results](ARGOS_COMPLETE_MIGRATION_RESULTS.md) record the current full-pipeline verification.

For a new package capture, add its Swift fixture and an explicit row to `Scripts/VisualTesting/package-inventory.json`; no historical PNG path is needed. For example:

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

`suite` is the Swift filename stem. `testName` and `captureName` are the exporter-sanitized `testName` and `named` arguments: replace runs of non-word characters with `-` and trim edge dashes (for example, `populatedLight()` becomes `populatedLight`). Explicit components use ASCII letters, digits, underscores, and internal dashes. The image identity must match exactly; dimensions are decoded pixels. Omit `legacy` and `variant` for new captures. Existing migration rows retain their historical mappings. Document the distinct visual risk and count change, then run `npm test` to verify the complete set.

Deleting PNGs from the current tree stops image churn but does not remove historical Git objects. History rewriting, force pushes, and repository cleanup remain a separately approved maintenance task described in [VISUAL_TESTING_POLICY.md](VISUAL_TESTING_POLICY.md#generated-files-and-historical-git-storage).
