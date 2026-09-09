# Chat verse preview — navigation history integration

## Approach

All three pre-rebase heads passed CI and exact-head Codex review, but main's newly merged #352 overlaps the reusable reader extraction and reading-position restoration. Rebase the stack onto `origin/main` at `99d6dac301e4bef2ed07f4df8c49fa0064f2ca39`, preserving separate foundation, preview and Chat PRs. Save recovery refs for all three current heads and use explicit old-parent boundaries for descendants; only rewrite the task-owned branches with exact remote leases. Keep all PRs draft and auto-merge off until renewed validation and approval.

Preserve main's chapter-history model, migration, bounded cursor, restore/retry queue and atomic full-record persistence. Adapt the foundation's exact-selection/translation handoff into that navigation-intent queue so Open in Bible waits for restoration and appends a visit once, while same-chapter opens retain history. Range links retain bounded selection and the active translation at execution. Remove the superseded generation-based startup restoration rather than keeping two competing state machines. Preview readers remain nonpersistent and are initialized immediately within the preview factory, so deferred full-reader restoration cannot delay preview selection or initial actions.

Preserve main's adaptive navigation height and history controls in BibleScreen. Pass the measured top reserve through the reusable chapter-content layout; keep preview-specific insets, optional chapter footer and floating bottom selection clearance independent. Retain chapter-bound invalidation of deferred study-sheet handoffs through the shared coordinator. Preserve background persistence flush and restore-time interaction guards. Integrate main's voice-input fixes and consolidated tests without reviving deleted redundant coverage.

## Risks and checks

- Restore/retry ordering can lose exact disjoint/empty selection or captured translation, or replace persisted history. Add gated regressions for exact preview handoffs before initial restore and during retry, append-once/same-chapter behavior, captured translation, and no preview writes/history changes. Retain existing main history and preview isolation coverage; update old startup tests to assert final navigation after the authoritative restore queue rather than the replaced implementation's immediate timing.
- Shared layout can regress the expanded full-reader toolbar or introduce navigation into the preview. Compare every Bible baseline from current main plus the three preview captures, preserving all main PNGs, and inspect native preview-to-reader history handoff at large text. Main adds two history captures; combined inventory becomes 628 (Bible281) with no extra integration captures expected.
- Rebase can silently lose unrelated main changes. Inspect range-diff and verify main's workflow pins, new history baselines/inventory rows, voice-input changes and database migration survive. Run complete Core/Bible/Chat suites and both app builds, plus full default 628-image comparison because inventory/driver changes meet in this integration. Do not record baselines automatically; investigate any differences.

## Review and delivery

Have a subagent critique this plan before resolving implementation conflicts and a separate code review after integration. Repeat affected validation for fixes, update PR descriptions around the final implementation and current test counts, push the three branches with leases, request current-head Codex approval, and resume joint CI/review monitoring every ten minutes. Once approved and green, verify branch protection and use the native atomic stack merge without bypasses; retain the worktree and simulator.

Plan review approved. Acceptance details: exact handoffs after an initial restore failure must register captured translation as explicit intent before Retry snapshots it; deferred study work must compare its captured chapter at execution, not depend solely on a later view onChange.

Foundation resolution approved by independent review. Main history/restore tests and the exact-reference integration pass; all 906 Bible tests across 92 suites pass after shared UI integration. A parameterized deferred-note regression failed for both action and book sheets before the captured-chapter guard, then passed in the complete suite. Helper and test lint and diff checks pass.
