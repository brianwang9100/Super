# Xcode 27 / Argos reconciliation

## Objective

Rebase `codex/xcode-27-pcc` onto fetched main `dac76b09` and reconcile the existing Xcode 27/PCC work with Argos, narration, chat motion, and the unit-test audit. Keep one combined PR. This is integration of the approved feature, not a new feature design.

## Global Constraints

- Keep iOS 26.0 deployment support. Fresh empty stores select local `system-default` on iOS 26 and `private-cloud-compute` on iOS 27+, regardless of transient readiness. Existing configured stores and selected identities remain unchanged.
- PCC registration on iOS 26 is disabled with `Private Cloud Compute (PCC) (only available for iOS 27)` and a persistent disclaimer. No cloud fallback or cloud request during seeding/hydration. Automatic title/suggestion processing remains local unless explicitly selected.
- Preserve current main's narration/credential-race fixes, chat motion, numeric-overflow fixes, unit-test audit, and content-sensitive Swift cache keys.
- Argos owns image baselines. Preserve main's 623 capture scenarios and register distinct PCC scenarios in the shared inventory. Do not restore Git PNG baselines or their comparison/recording workflows. Keep test-only renderers out of Release apps.
- Pin Xcode 27.0 beta 6 / `27A5252f`, iOS 27.0 / `24A5423a`, iPhone 17, and XcodeGen 2.45.4 consistently. Use main's shared simulator-pins.json as source of truth. Preserve the separate iOS 26 compatibility smoke path.
- Preserve required checks and documented coverage floors (Core 80%, applets 70%); never lower thresholds or silently skip failing tests. Reconcile the pending iOS coverage collector with Argos's serialized export contract; report any remaining unmet gate honestly.
- Preserve all pending fixes, including the iOS 26 liveness timing regression fix. Keep a named recoverable Git checkpoint before history rewriting. Do not commit Python caches, change developer accounts/signing, operate Chrome, or change global Xcode/OS/simulator state.

## Approach and risks

The checkout contains a fully resolved old-main merge (`98e2e248`) and two additionally modified smoke-test files. Complete a local checkpoint and retain a backup ref. Consolidate the feature delta relative to that old main into a recoverable integration commit before rebasing onto the current main; the backup retains the original feature commits and merge resolutions. This avoids replaying obsolete binary baseline updates through many historical commits.

Require identical tree hashes between checkpoint and consolidated commit before rebasing. Keep `ios-test` owned by `argos.yml`, with both the package capture and coverage outcome contributing to its dependencies; never define that required context twice. For coverage, reuse the coverage-enabled build and isolated visual suite results from the capture driver, add a logic execution excluding exactly those discovered suites, and aggregate raw executable-line hits from these same-source/same-build results. Validate the expected test inventory against the complete union, disclose skips/parameterized executions, and fail closed on missing, duplicate, failed or mismatched evidence. Do not average percentages or run all visual suites concurrently. If real Xcode evidence contradicts this architecture, report the precise issue before substituting another design.

Main deleted image files modified by this branch. Resolve these to Argos's no-tracked-image policy, porting the branch's new visual fixtures to `verifyVisualSnapshot` and inventory entries. Manually reconcile overlapping Settings/bootstrap/privacy text rather than accepting a whole side. Current main #343 refreshes unit tests/cache keys but does not implement the pending full-iOS coverage gate.

## Task 1: Rebase and reconcile

Work only in `/Users/bwang/.codex/worktrees/6a40/Super`. Read applicable instructions and current main's testing/visual policy before implementation. The controller creates the backup/consolidated checkpoint and starts the rebase; resolve that rebase and complete integration.

1. Reconcile all text conflicts, retaining both PCC semantics and main's behavior. Preserve main's canonical AGENTS guidance with necessary PCC-specific constraints only.
2. Retire tracked package image baselines and obsolete Git-baseline migration scripts/workflows/tests. Preserve every relevant visual scenario through main's exporter and inventory; map any intentional consolidation explicitly. Extend native Settings previews only where they add a distinct PCC risk.
3. Reconcile Argos, iOS, Swift, TestFlight and compatibility workflows onto the exact 27 pins. Preserve shared pins, stable aggregate checks, OIDC upload integrity, content-sensitive caches and serialized capture isolation.
4. Integrate the pending full-iOS coverage collector without breaking the visual exporter contract or duplicating incompatible visual execution; retain audit artifacts, source identity, complete-test validation and documented floors. Fix the inherited simulator-guard shell fail-open behavior if it remains in the final code, with a failing regression before the fix.
5. Update current toolchain/test/CI docs and the existing PCC plan; label old validation as historical. Run focused Python/hook/inventory/workflow checks and relevant regression tests. Regenerate the project if required. Commit the resolved integration, self-review, and report exact changes, test evidence, and remaining local/CI/manual gates. Do not push or create a PR in this subtask.

## Task 2: Validate and deliver

After task 1's independent review, run all affected package suites with the installed Xcode 27, check generated project consistency, build both unsigned simulator apps, and run the complete Argos capture if the exact worktree-owned runtime is available. Execute the changed iOS 26 compatibility smoke on the reconciled revision (both apps, Debug and Release); if the required runtime is unavailable, record that missing gate explicitly. Use the worktree helper; do not modify shared simulator installations or force service resets. Record exact environmental blockers if unavailable. Re-run affected validation for any review fixes.

Review the whole feature diff independently. Then update/create one draft PR using the repository template, preserving required checks and disabling any auto-merge before a push. Publish rewritten history only with an explicit expected-head lease after checking the remote. Do not declare completion/merge readiness based on pre-rebase CI, unreviewed Argos images, or unavailable PCC signing/device tests. Observe applicable CI/review through product monitoring, with no browser observation.

## Validation record

Reconciled revision `c02220f1` passed all four local package suites (Core 352,
Chat 1152, Bible 841, Todo 87), both unsigned simulator app builds, 211 Python
checks, hook fixtures, and workflow lint. GitHub's four package suites, both
app builds, native capture, and iOS 26 compatibility smoke also passed. These
results do not replace validation of subsequent fixes.

The full local capture stopped at Chat's declarative scroll suite: Xcode 27's
automatic offset adjustments caused six assertion failures. Native's 48
captures and Bible's 276 captures completed; Bible's complete test union had
zero skips and 88.90% raw physical-line coverage. No complete 652-image result
or partial-baseline upload is claimed.

Follow-up fixes preserve optional default-registration recovery in both app
bootstraps and disable automatic offset adjustments only in the iOS 27+
transcript. The narrower value-scoped scroll approach retained a 196-point
live-to-saved handoff jump, so the modifier covers descendant transactions.
All 13 focused UIKit scroll functions pass, including a positive-controlled,
same-run rendered check of reading-position preservation during resizing.
This adds no stored image baseline or capture-inventory entry.

For the app-only bootstrap regression, unsigned Release builds of both apps
first reproduced `Bootstrap failed` with an insert-aborting SQLite trigger in
fresh, backed-up synthetic containers on the worktree-owned simulator. Fixed
builds reached their normal shells while that trigger remained installed and
model rows remained empty. After removing the test triggers, both apps seeded
and selected `private-cloud-compute` on relaunch. Both Debug and Release app
rebuilds passed; no injected faults remain. Independent scoped code reviews
found no serious issues in either follow-up fix.

The related MessageList snapshot suite passed 31 tests, and focus/turn/composer
integration passed 11 tests. Actual animated send/retry/regenerate and drag
interruption remain unverified: the simulator HID helper cannot locate
SimulatorKit under Xcode 27, and native UI fallback reports a locked Mac.
No real model request or temporary retry fault was created during that check.

Remaining gates: final-source full capture/coverage, animated in-app scroll
acceptance, current-revision CI/Codex approval and Argos review, plus PCC
capability/signing and real-device cloud validation. Keep the PR draft and
auto-merge disabled until the applicable acceptance gates are satisfied.
