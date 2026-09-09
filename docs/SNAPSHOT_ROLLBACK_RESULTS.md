# Repository snapshot rollback

## Scope

Repository PNG baselines replace Argos storage and visual approval. Current application code, fixture coverage, renderer fixes, pinned simulator environment and behavior assertions remain unchanged. The inventory remains **623 → 623**: Bible 276, Chat 244, Core 20, Todo 42 and native previews 41.

Package tests use their original Point-Free image strategies through `verifyVisualSnapshot`. Default tests compare even when exporting images. Recording is explicit, local-only, and rejected in CI; missing baselines never auto-record. Native previews compare against their own committed PNGs and preserve expected, actual, diff and JSON evidence.

The workflow is `snapshots.yml`. It retains `ios-test` and `native-previews`, fails when any required comparison shard fails or is skipped, and validates the complete image inventory. Argos upload, CLI dependencies, OIDC permission and fork authentication restrictions are removed. The separate live removal of the external `argos` required status happens only after replacement CI and current-revision Codex approval. All other branch protections remain enforced.

## Baseline provenance

All 623 restored PNGs are byte-identical to the artifacts of main commit `dac76b09dbe00a5f494e089431b7abaa5b7c4afd`, [run 34291959454](https://github.com/brianwang9100/Super/actions/runs/34291959454). That run completed all captures but failed at the quota-limited upload. Each downloaded shard's manifest, commit, run/attempt, inventory, dimensions, decoding and hashes were independently validated.

Of those images, 599 also match the earlier approved main [run 34275754482](https://github.com/brianwang9100/Super/actions/runs/34275754482). The other 24 are Bible narration screenshots showing UI already merged in [PR #340](https://github.com/brianwang9100/Super/pull/340): the prefetch setting and updated provider status/actions. All 24 before/after pairs were independently inspected against that source change. The rollback does not revert those changes.

The restored baseline files total 82,366,893 bytes. This is working-tree PNG size, not incremental Git storage or transfer size. Future baseline changes will again accumulate in Git history. The separately planned history cleanup and its monitor remain paused; no history rewrite or recovery-archive deletion is included.

## Native rounding policy

An initial exact comparison reproduced the previously measured local-versus-hosted rendering difference: 20 of 41 images differed at 167 pixels total, with maximum RGB channel delta 1 and no alpha differences. All 41 new local render files were byte-identical to the independent earlier local rehearsal outputs. The largest affected fraction was 38 of 539,082 pixels (0.00705%).

Native comparison therefore permits RGB channel delta at most 1 on at most 0.01% of pixels per image; alpha must be identical. Integer arithmetic enforces the inclusive pixel-count bound. This intentionally accepts sparse color rounding, not layout or larger color changes. Every accepted difference remains identified in the JSON report with expected/actual/diff artifacts. CI baseline files were preserved. Boundary tests reject excessive changed-pixel counts, stronger channel changes and alpha changes.

## Validation

- Independent plan review and implementation review: no outstanding serious findings, including a separate review of the bounded rounding policy.
- macOS package suites: Core 318, Bible 835, Chat 1,103, Todo 87; **2,343 passed**.
- Focused Core simulator verification: build-for-testing and **12 helper regression cases passed**, covering comparison while exporting, missing/changed baselines, local recording, CI aliases, asynchronous timeout and callback behavior.
- Python guards: **38 native and 27 pipeline tests passed**.
- Native preview rendering and all 41 comparisons passed after applying the independently reviewed rounding policy to the preserved rendered output.
- Full package simulator comparisons passed: Bible 276, Chat 244, Core 20 and Todo 42 (582 total). Aggregation of these package artifacts and the 41 validated native previews passed the complete 623-image inventory. The first full command stopped at the native exact-comparison discrepancy; the preserved native output passed the revised comparator, then all package drivers and full aggregation completed successfully. Remote CI results are tracked in the rollback PR.
- SwiftLint for changed Swift files, workflow `actionlint`, baseline provenance/inventory validation and `git diff --check` passed.

See [SNAPSHOT_TESTING.md](SNAPSHOT_TESTING.md) for default comparison, explicit recording and review commands. Open PRs using the retired workflow need to update from the rollback revision and rerun checks; their Git ancestry is preserved.
