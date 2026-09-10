# Comment Audit

Completed source review against `8f7f674db91d34fa81b8eac0c29df733c96c7b29` (September 9, 2026), following the [reviewed plan](superpowers/plans/2026-09-09-COMMENT_AUDIT.md).

## Scope and result

Reviewed all **861 maintained files**: 804 Swift files plus 57 scripts/configuration files, including tests, hidden tracked tooling, and design JSX. Changed 771 files; retained 90 unchanged. Dependencies, generated/vendor output, fixtures, bundled prompts, product copy, and historical documents were excluded. The original 810-file audit was reconciled with two updates from main: 55 new or moved paths, two replaced paths, and two upstream deletions. The second update rechecked 31 existing paths and reviewed all 27 newly added Swift files.

The policy in `AGENTS.md` now makes documentation optional for public declarations and test suites. Comments explain non-obvious contracts, invariants, rationale, or workarounds. The audit removes narration and stale history while preserving provider replay signatures, tool-result pairing, persistence formats, cancellation ordering, geometry workarounds, and operational directives. Independent reviews covered every batch and the final integration; findings were addressed.

| Area | Files | Swift comment lines, before → after | UTF-8 bytes, before → after |
|---|---:|---:|---:|
| Chat Swift | 289 | 13,187 → 2,182 | 2,867,796 → 2,147,816 |
| Bible Swift | 301 | 7,202 → 1,393 | 1,957,963 → 1,580,379 |
| Core Swift | 134 | 3,330 → 667 | 581,530 → 413,742 |
| Todo Swift | 54 | 731 → 470 | 206,982 → 190,000 |
| Apps Swift | 17 | 1,323 → 208 | 170,706 → 100,009 |
| Scripts Swift | 9 | 106 → 57 | 33,610 → 30,656 |
| Other code/config | 57 | — | 352,869 → 323,742 |
| Total | 861 | 25,879 → 4,977 | 6,171,456 → 4,786,344 |

Full-line Swift comment candidates fell by 20,902 (80.8%); source size fell by 1,385,112 bytes (22.4%). Counts use identical before/after file sets. Prefix counts exclude trailing/block comments and can include comment-looking strings; all string contents were preserved. No tokenizer was available, so no token-saving percentage is claimed. Source measurements exclude this report and the plan. Detailed per-file dispositions and temporary checkers remain in ignored `.build/comment-audit/`.

## Validation

- All 804 Swift files parse and preserve executable token/syntax trees against the integrated baseline; functional directives and their target statements are unchanged. All 30 Python ASTs, including docstrings, and six JSX/MJS trees match. Twelve YAML configurations retain ordinary values; ten edited embedded shell bodies retain executable content and pass syntax checks.
- Under Xcode 26.4.1, package suites passed with parallel execution, coverage, and warnings treated as errors: Chat 1,134; Bible 937; Core 335; Todo 87 (2,493 total). No test declarations or assertions changed.
- 108 representative iOS simulator tests passed: snapshots in ChatScreen, MessageList, BibleScreen, BibleChapterReader, BibleChapterPreview, AnnotationSheetContainer, MarkdownText, and TodoScreen, plus UIKit preview-presentation readiness tests. Both `Super` and `SuperBible` simulator builds passed on the registered worktree simulator; no signing or recording was performed.
- Script suites passed: simulator tooling 29, visual-testing guards 48, PreviewPilot guards 38, plus hook fixtures. SwiftLint and whitespace checks pass; expanded baseline comparison has no new diagnostics (187 before, 176 after).
- The tracked inventory contains 545 package images and 41 native previews, totaling 586. Audit capture-count delta: **0**. No baseline images, fixtures, resource strings, or operational configuration values changed.

## Existing limitations

Full actionlint reports the same TestFlight ShellCheck SC2046 warning reproduced on `ffbc76d6` (the workflow is unchanged in `8f7f674d`); actionlint with ShellCheck disabled passes. The ChatLiveLLM script's missing `toolCallAwaitingConfirmation` switch case was reproduced on the original source during the audit. These unrelated code issues were left unchanged.
