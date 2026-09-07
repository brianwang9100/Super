# Argos visual testing

This project captures native iOS `#Preview` scenarios and uploads PNGs with the Argos CLI, following the [any-framework quickstart](https://argos-ci.com/docs/quickstart/any-test-framework.md). No Playwright or app runtime SDK is involved.

## Local usage

Prerequisites: macOS, Node 22 or newer, Python 3, Xcode 26.4.1 / 17E202, iOS simulator runtime 26.4.1 / 23E254a, and XcodeGen 2.45.4. Keep only the exact 23E254a build for the iOS-26-4 runtime identifier.

```sh
npm ci --ignore-scripts
npm test
# Set ARGOS_TOKEN in your shell environment, then:
npx --no-install argos upload ./screenshots
```

`npm test` runs the Python guard tests, obtains the registered worktree simulator through `Scripts/worktree_simulator.py ensure`, discovers and renders 23 previews, validates the full inventory and exact dimensions, and decodes all PNGs. It publishes only PNGs to the ignored `./screenshots` directory. An explicit UUID argument or `ARGOS_SIMULATOR_UDID` must match the helper's registered device. Ownership is recorded in the common Git directory; names start with `SuperWT-`. The helper isolates sibling worktrees and safely follows moved worktrees. The pilot still independently checks its exact Xcode/runtime/device pins. Old unregistered pilot devices are not reused or automatically removed. See [simulator lifecycle](TESTING.md#worktree-simulator-lifecycle).

The npm command is the native visual-test entry point. The existing Swift package, behavioral, database, and legacy snapshot suites still run through their existing commands and CI checks.

Screenshots are regenerated on each capture. A failed capture does not reach the upload step in CI. Logs, xcresults, sidecars, and the exact legacy parity report stay under `.build/PreviewPilot/run-*/`; no renderer sidecar is uploaded as an Argos snapshot.

The `--argos` mode deliberately reports the reviewed Point-Free pixel differences without failing solely on those differences. It still rejects missing/invalid images, incomplete comparisons, changed dimensions, oversized files, failed tests, and failed discovery. Direct `python3 Scripts/PreviewPilot/run.py <UUID>` retains the strict legacy-parity exit. Neither mode changes existing Point-Free baselines.

## GitHub Actions

[`.github/workflows/argos.yml`](../.github/workflows/argos.yml) runs on pull requests, pushes to `main`, and manual dispatch. It uses `macos-26`, pinned Xcode and XcodeGen, commit-pinned actions, and `npm ci` with the exact CLI dependency in `package-lock.json`. It runs `npm test`, then `npm exec -- argos upload ./screenshots`. Capture evidence is retained for seven days, including on failures.

CI uploads prefer GitHub OIDC: `id-token: write` lets the CLI obtain a short-lived GitHub-signed identity, which Argos verifies before granting build-scoped upload credentials. GitHub OIDC must also be enabled in the Argos project's authentication settings. `ARGOS_PROJECT` selects the project and read-only `GITHUB_TOKEN` provides PR metadata. Keep `ARGOS_TOKEN` unset, since it takes precedence over OIDC. The previously configured repository secret remains unused; local uploads can still use the user's shell token.

Tokenless is the fallback when OIDC is unavailable: Argos verifies the repository, commit, branch, and in-progress workflow through GitHub's API. The previous tokenless CI upload was rejected because tokenless authentication was not enabled in this Argos project, despite successful capture. Enable that option separately if fork PR uploads need it, and validate a fork run before relying on the fallback. See [GitHub Actions authentication](https://argos-ci.com/docs/learn/integrations/github-actions-authentication.md).

No branch protection or existing required check is changed. Before making Argos required, test a changed screenshot, missing screenshot, failed capture, failed upload, review rejection, and approval. Keep current checks required during this trial.

## First build and baseline

The initial capture and upload succeeded on 2026-09-06: [build #1](https://app.argos-ci.com/brianwang9100/Super/builds/1), with 23 added screenshots, 0 changed, and 0 removed. Argos reports `changes-detected`, as expected for the new image set, with no reference build yet. The repository's `ARGOS_TOKEN` Actions secret is configured. Local capture evidence is `.build/PreviewPilot/run-2rccaqq9/`; all original eight guard tests and the 25-case capture/layout test run passed. Review hardening initially added six renderer-integrity and simulator-identity guards (14 total), plus an iOS fixture test for explicit Reduce Motion overrides. Integration with the shared simulator helper replaces the two naming tests with three registered-device selection tests (15 Python guards total). The capture target also includes two UIKit text-size inheritance regressions; both probes fix the size category to Large. A corrupt-image control was rejected before upload.

A local upload uses the current Git branch and commit. Uncommitted fixture/tooling changes are included in the captured images but are not a committed baseline. The first upload from `codex/argos-visual-testing` is an onboarding build. The setup must land on `main` and run there to establish the main-branch reference; do not relabel this working-branch build as `main`. Until a suitable reference exists, Argos may report an orphan build. [Baseline behavior](https://argos-ci.com/docs/quickstart/any-test-framework.md).

Review all 23 initial images: 21 composer scenarios and 2 UIKit probes. Renderer fixes, repeatability evidence, and the one-to-one legacy mapping are documented in [the pilot results](PREVIEW_VISUAL_TESTING_RESULTS.md). Coverage expansion to the remaining native snapshots is a subsequent package-by-package migration.

## Verified diff demonstration

[Build #2](https://app.argos-ci.com/brianwang9100/Super/builds/2) successfully compared against build #1 on the same branch and commit: **1 changed, 22 unchanged, 0 added, 0 removed**. Only `composer_typed_light` temporarily changed its fixture text from “Hello world” to “Hello Argos”. Argos identified that exact screenshot as changed. The original preview source was restored byte-for-byte after capture; all 23 regenerated local PNGs match build #1 byte-for-byte. The demonstration diff is left unapproved for review. This proves upload and comparison, not enforcement through branch protection.

## Usage

The pilot uploads 23 screenshots per run. The full existing inventory contains 543 baseline images, so count PR updates, retries, and main captures before expanding. Consult [current pricing](https://argos-ci.com/pricing). Open-source sponsorship is conditional and commercial eligibility must be checked; it is not assumed by this integration.

## Migration and local workflow

Argos replaces repository-hosted visual baselines and local pixel comparison for migrated scenarios; CI still renders the screenshots. After migration, developers can use Xcode previews and targeted local captures for feedback while CI performs the complete visual comparison. Running the full visual suite locally need not be a blanket pre-PR requirement. Unit, integration, and database snapshot tests remain local requirements for code changes.

`screenshots/` is already ignored in the root `.gitignore`. Keep preview fixtures, capture scripts, and the expected screenshot inventory in Git. Do not globally ignore `__Snapshots__/`: it still contains required Point-Free baselines and can also contain non-image snapshots that remain useful. Ignoring a path does not untrack existing files or remove old Git objects.

The pilot is not yet independent of legacy images: `verify.py` checks composer baseline hashes and `ComparePreviewImages.swift` reads them for parity. Replace that migration-only contract with a standalone capture inventory before deleting composer PNGs. Complete the baseline and required-check validation described above before retiring equivalent legacy visual tests. See [VISUAL_TESTING_POLICY.md](VISUAL_TESTING_POLICY.md) for the measured inventory, proposed shortlist, retirement criteria, and history-cleanup options.
