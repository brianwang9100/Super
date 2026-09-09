# Restore repository snapshot testing

## Scope and approach

Replace Argos baseline storage and upload/review with checked-in PNG baselines and failing local/CI snapshot comparisons. Preserve current main UI, fixtures, stable names, renderer fixes, simulator pins, behavioral assertions, and exact capture inventory (currently 582 package images plus 41 native previews). Git history cleanup and its monitor stay paused. Do not rewrite history or remove recovery evidence.

1. Restore Point-Free comparison in the existing test-only `verifyVisualSnapshot` facade so direct simulator tests compare repository baselines. Preserve its capture mode for validated inventory/artifacts. Restore package PNGs from approved original-main CI artifacts, reconcile current source differences, and support explicit local recording while refusing CI recording. Missing baselines must fail.
2. Add repository comparison for native preview output, with expected/actual/diff artifacts and negative regression tests for missing, changed, unexpected, corrupt and wrong-sized images. Keep the native renderer and its 41 previews. Default commands compare; recording must be explicit and unavailable in CI. Preserve exact inventory validation before comparison/recording. Package Point-Free strategies retain their original tolerances; native comparison should begin exact, with any necessary bounded rounding policy supported by inspected evidence and documented rather than a blanket waiver.
3. Replace `argos.yml` with a repository snapshot workflow retaining `ios-test` and `native-previews` as fail-closed required contexts. Remove CLI/upload/OIDC permissions, unnecessary Node setup, fork restrictions, and Argos-specific environment names. Keep artifacts on failures. Do not combine coverage pruning or changed-path optimization with this rollback.
4. Update `.gitignore`, root/nested agent instructions, active testing/CI/setup docs and guards. Baselines are tracked; scratch captures and diff artifacts remain ignored. Keep guidance limiting new screenshots. Historical reports remain labeled historical rather than rewritten. Remove Argos-only dependencies and commands.
5. Validate guards, each affected package's macOS suite, complete simulator comparison and native preview checks. Inspect baseline provenance and any differences against approved originals. Review implementation independently, address findings, and open a draft PR with repository template and count/provenance evidence.
6. Monitor CI and Codex together every ten minutes. Once replacement checks genuinely pass on the current revision and Codex approves, remove only the external `argos` required context while preserving all other contexts/App bindings and protections; this is authorized by the rollback request. Make ready and enable auto-merge only after review and checks, then verify merge. Do not fabricate Argos approval or bypass checks. Retire repository Argos integration where possible without deleting account data or affecting other projects.

## Risks

- Archived baselines reflect an earlier approved main: compare source and output before adopting them on current main; do not revert newer UI.
- Direct tests must never silently fall back to capture-only success; CI must not auto-record missing or changed baselines.
- Native previews need their own comparison path; deleting upload alone leaves them unprotected.
- Restored PNGs grow Git history again. This change avoids force pushes and preserves open PR ancestry.
- Some open PRs still use the old workflow until refreshed from the rollback. Preserve replacement check names and explain branch-update requirements.
- Local/hosted rendering can differ at one channel level. Report and inspect; avoid broad tolerance changes.

## Validation and delivery ledger

- Starting main: `dac76b09dbe00a5f494e089431b7abaa5b7c4afd`.
- Existing worktree reused on `codex/restore-repository-snapshots`; two untracked history-cleanup documents remain excluded from this PR.
- Approved baseline source: `.build/history-cleanup/main-ci-artifacts/visual-*/images`, 623 PNGs, original main run 34275754482. Preflight run 34284367863 independently reproduced every image byte-for-byte.
- Plan review: reviewer required the package driver to compare AND export, never capture-only success. Add facade regression tests proving missing/changed baselines fail with output enabled and CI cannot record through flags or Point-Free ambient settings. Accepted; this applies to every production fixture. Explicit `directory` remains only an isolated exporter unit-test seam, guarded against use in production suites.
- Implementation, local validation, independent change review, draft PR and required-check transition: pending.

### Implementation progress

- Package facade restored Point-Free comparison using the original diffing strategy. Public capture-only escape hatch removed; CI policy forwarded explicitly into simulator test runners. Twelve focused simulator helper cases passed after Core build-for-testing.
- Native preview comparison, explicit local recording and expected/actual/diff artifacts implemented; all 41 archived native baselines restored.
- Workflow replaced with `snapshots.yml`, retaining required aggregate names and removing upload/OIDC/Node steps. Root npm commands remain dependency-free convenience aliases.
- macOS suites passed: Core 318, Bible 835, Chat 1,103, Todo 87 (2,343 total).
- Current main run 34291959454 provided all 623 captures. Of these, 599 match the prior approved main byte-for-byte; 24 Bible narration images reflect newer merged UI and are under independent visual review.
- Full local simulator comparison underway; independent whole-change review underway. No remote settings changed and no history cleanup resumed.

### Rounding decision and baseline provenance

- Independent review verified all 623 current-main artifact manifests/hashes/dimensions from run 34291959454; 24 narration images were visually reviewed against merged PR #340 and restored. All committed PNGs now reflect current main; capture count stays 623 → 623.
- First native exact comparison reproduced the historical local/hosted discrepancy: 20 images, 167 RGB pixels, maximum channel delta 1, no alpha differences. A separate reviewer recomputed these metrics from actual image pairs; worst fraction was 38/539082 = 0.00705%.
- Ruling: native comparison may accept only RGB channel delta ≤1 on ≤0.01% of pixels per image, with alpha exact. This is explicitly a bounded rounding tolerance, not exact equivalence. It preserves CI originals and emits evidence for accepted rounding. Add rejection tests for stronger, widespread, or alpha differences.
- Independent whole-change review found no serious issues before this narrow comparator adjustment; scoped re-review is in progress.

- All582 package simulator snapshots passed (Bible144s, Chat147s, Core20s, Todo43s). Native41 comparison and complete623 artifact aggregation passed. Both implementation reviews are clean. Excluded PNG baseline directories from SwiftPM resources; final macOS rerun passed all2343 tests with zero unhandled baseline-resource warnings. Draft PR next.
