# Comment Audit

Baseline: `c6a49ba3` (September 9, 2026). Implementation follows the [reviewed plan](superpowers/plans/2026-09-09-COMMENT_AUDIT.md).

## Scope and method

Review all 810 maintained source/configuration files, including 756 Swift files, tests, scripts, workflows, design JSX, and tracked hooks/configuration templates. Exclude dependencies, generated/vendor artifacts, data/image fixtures, bundled prompts, and historical documents. Preserve executable code, runtime strings (including Python CLI docstrings), directives, legal notices, and necessary contracts/workaround rationale.

The initial Swift scan found 26,157 full-line comment candidates among 125,915 lines: 17,832 `///` lines and 8,325 ordinary `//` lines. These prefix counts exclude trailing/block comments and can include strings. Repeat the same method and original file set for the final comparison; measure source bytes separately and claim token savings only with an identified tokenizer.

## Decisions

The root policy no longer requires comments on all public declarations/test suites. Keep comments that explain information the code cannot express; remove restatements and stale history, and shorten useful rationale without losing its constraints.

Calibration removed routine `Clock` member narration and test-suite summaries while retaining synchronous locking rationale, cold-launch-only semantics, and event correlation contracts. Later batches preserve provider replay signatures, tool-result pairing, SQLite migration constraints, cancellation ordering, UI geometry workarounds, font registration, and scoped rendering tolerances. Repeated implementation histories and stale roadmap notes were removed or shortened.

All 79 root/tooling paths, 176 Core/Todo paths, 271 Bible Swift paths, 123 Chat test paths, and 129 Chat source/manifest paths are reviewed (778 unique paths). The remaining 32 Chat provider/session files are in progress. Detailed per-file decisions and original sources remain in ignored `.build/comment-audit/`. Integration uses a separately preserved `ffbc76d6` baseline of 836 maintained files (779 Swift), including 28 new or moved paths reviewed for follow-up cleanup; aggregate measurements will use that identical before/after set.

## Validation

Completed local checks under Xcode 26.4.1:

- Core: 317 tests; Todo: 87; Bible: 827. Chat is pending source completion.
- Swift syntax/token comparisons are unchanged for completed batches. All 123 Chat test files parse without errors and match the baseline code.
- Representative iOS simulator snapshots passed for Core MarkdownText, TodoScreen, BibleScreen, and BibleChapterReader. Chat simulator coverage and final combined app builds are pending.
- Python ASTs (including runtime docstrings), JavaScript/JSX syntax trees, and YAML structure match. Reviewed workflow shell bodies pass syntax checks. Visual-testing guards: 27 tests; PreviewPilot guards: 38 tests.
- Scoped SwiftLint comparisons introduce no new diagnostics in completed batches. Whitespace checks pass.
- Independent reviews cleared the root/tooling, Core/Todo, supplemental Core, and Bible batches. Chat tests and the 129 completed Chat source files also passed independent review.

The original 623-image inventory is unchanged by the audit. Main has since advanced with separately reviewed features and capture consolidation; integration will preserve that updated inventory and measure the audit’s capture-count delta against it. No new tests or baseline recordings are needed for comment-only changes.

## Existing limitations

The ChatLiveLLM script build fails on a missing `toolCallAwaitingConfirmation` switch case; the same failure was reproduced on the original source. Full actionlint reports existing ShellCheck SC2046 diagnostics in the TestFlight workflow; actionlint with ShellCheck disabled passes. Neither issue was changed by this audit.
