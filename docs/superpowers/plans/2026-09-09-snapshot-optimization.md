# Reduce redundant snapshots and avoid irrelevant CI captures

## Objective

Reduce visual-test maintenance and CI work while preserving distinct layout, theme, typography, accessibility and known-regression coverage. Keep repository PNG comparison and all existing required checks enforced. Git history cleanup stays paused.

Starting main: `c6a49ba3` (623 captures: Bible 276, Chat 244, Core 20, Todo 42, native 41). Worktree branch: `codex/streamline-snapshot-coverage`. Untracked history-cleanup documents are unrelated and excluded from delivery.

## Approach

1. Audit current source fixtures, rendered images and existing behavioral tests. Review Chat/Settings/transcript and Bible/narration/reader/picker in parallel; inspect Core/Todo's smaller suites for safe opportunities. Retire only cases with explicit retained visual and behavioral evidence. Do not automatically delete identical font-scale/XXL fixtures, unique error states, accessibility risks, renderer probes or known regressions. Preserve existing behavioral assertions and all retained PNG bytes; do not re-record to shrink the inventory. Document every retired image and replacement. No arbitrary image-count target.
2. Update source suites, tracked inventory and PNGs together. Extend the retirement mapping and add meaningful validation that retired images are absent and retained evidence exists. Preserve the complete-shard inventory checks.
3. Make the snapshot workflow always start and use a cheap change-classification job. Positively identified documentation-only PR changes may skip all five expensive macOS capture shards. Main pushes and manual dispatches run the full suite. Every other change, including unknown paths, source, tests, assets, packages, renderers, inventory, pins and workflow changes, runs the full suite. Prefer conservative skipping over fragile per-package dependency guesses. Validate diff provenance and renamed/deleted paths; unavailable or malformed change data must fail closed.
4. Keep `ios-test` and `native-previews` as always-reporting required checks. They may succeed for an explicitly validated docs-only skip, but must reject failed discovery/classification or unexpected skipped/failed/cancelled capture legs. For code changes, all five compared artifacts and complete inventory validation remain required. No workflow-level path filters, partial-upload convention, or protection edits.
5. Add regression tests for classifier boundaries and required-gate behavior: ordinary docs, mixed docs/code, markdown fixtures, renames/deletions, shared code/assets/config, forks, missing diff data, failed classification and failed/skipped capture jobs. Test the actual helper called by workflow. Exercise full-run behavior on the implementation PR and a docs-only control against the implemented revision if feasible.
6. Run affected package macOS suites and complete simulator visual capture; verify retained images remain byte-identical to starting baselines and inventory counts match the audited reduction. Run workflow lint, guards and independent change review. Open a draft PR with count deltas, retirement rationale, CI policy and measured timings. Monitor CI/Codex every ten minutes, fix findings, and enable auto-merge only after current-head approval and passing applicable CI. Preserve unrelated open work and the paused cleanup.

## Risks and validation

- A visually identical output can indicate an ineffective fixture instead of redundant coverage; retain questionable scale cases for a dedicated fix.
- Markdown fixtures and generated runtime assets can affect screenshots. Only a narrow reviewed docs allowlist may skip; unknown changes must run captures.
- Required jobs must report even when capture jobs are intentionally skipped, and distinguish that policy from infrastructure failure.
- Source/inventory/baseline disagreement must fail, not silently reduce expected coverage.
- Screenshot-count reduction is not a proportional CI speed claim; compilation, simulator boot and runner queues remain significant. Record actual comparison count, image bytes and observed timings separately.

## Review and progress

- Current-source Chat and Bible audits and independent CI design review completed.
- Core/Todo audit: retain all captures; apparently identical font-scale and fixed-chrome sentinels need targeted behavioral proof before any future retirement.
- Independent plan review approved with refinements, recorded below before implementation.
- Skip allowlist: Markdown under `docs/` and root `README.md`, `TODO.md`, `AGENTS.md`, `CLAUDE.md` only; nonempty validated changes required. Unknown paths remain full.
- Checkout uses the tested synthetic PR merge; verify workflow SHA and the event's base/head parent SHAs before a NUL-delimited, rename-disabled base-to-merge diff. Missing or stale provenance selects full. Fork events retain read-only permissions.
- Inventory/discovery and platform-independent capture guards run even on docs-only PRs. Discovery output uses a separate checked assignment to propagate subprocess failure.
- Required gate truth table: successful discovery + exact docs-only mode + exactly skipped expected captures passes an explicit skip; successful discovery + full mode + successful captures proceeds to full inventory validation. Every other combination fails. All native artifact steps run only in full mode after the gate succeeds.
- Retirement evidence names exact IDs, retained images and actual behavioral test declarations; move embedded assertions if deleting their only owner. One-time retained PNG hashes are compared to starting commit, without prohibiting future reviewed baseline updates.
- Bible audit approved: 28 justified removals, preserving 248 Bible captures; full per-image evidence will be incorporated into the retirement map. Core 20/Todo 42/native 41 remain unchanged. Chat audit approved: 18 removals, preserving 226 Chat captures. No control PR is necessary for this change; real Git fixture and actual gate execution tests plus the implementation PR will validate CI selection.

## Implementation validation

- Exact inventory: 623 → 577; packages 582 → 536 (Bible 248, Chat 226, Core 20, Todo 42), native 41 unchanged.
- All 577 retained PNGs byte-identical to starting commit. Current tracked baseline payload 82,366,893 → 73,298,929 bytes (9,067,964 bytes removed); Git history remains untouched.
- Retirement guard validates all 49 historic/current retirement records against live registered PNGs and actual behavioral test declarations.
- Package macOS suites: Bible 827, Chat 1096, Core 317, Todo 87 tests pass (2,327 total).
- VisualTesting 48 and PreviewPilot 38 guards pass; 20 new CI tests include real Git merge/depth fixtures, CLI/discovery failure propagation and gate truth tables. Workflow actionlint and diff checks pass.
- Full 577-image local simulator comparison passed in 384.9 seconds (warm local caches, not a comparative CI speed measurement), including UIKit assertions. Xcode 26.4.1 /17E202, iOS 26.4.1 /23E254a, iPhone 17. Independent change review approved without findings. CI and Codex review pending draft PR.

## Integration with chapter-history PR #352

Main `99d6dac3` adds two Bible navigation-history captures and updates the reader, toolbar, and toast baselines. Preserve every retained baseline and inventory row from that revision. Revalidate the original retirement mappings against the updated visible controls; the new history gallery and narrow accessibility case are not retirement candidates. Current proposed count is 625 → 579, including Bible 278 → 250; Chat 226, Core 20, Todo 42, and native 41 are unchanged from this PR's original consolidation.

The updated Bible macOS suite passes all 866 tests. Full 579-image simulator comparison passed in 321.1 seconds with warm local caches; all 86 guard tests passed. Independent re-audit and rebase review approved without findings. All 579 retained PNG hashes match main `99d6dac3`; tracked payload is 83,412,965 → 74,318,783 bytes (9,094,182 bytes removed). Rebased CI and a new current-revision Codex approval are required before readiness or auto-merge; prior approval cannot transfer across the changed head. Git history cleanup remains paused.
