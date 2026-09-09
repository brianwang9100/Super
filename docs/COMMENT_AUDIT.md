# Comment Audit

Completed source review against `ffbc76d69b44ec82cf3264357a25a42f7f1e0909` (September 9, 2026), following the [reviewed plan](superpowers/plans/2026-09-09-COMMENT_AUDIT.md).

## Scope and result

Reviewed all **836 maintained files**: 779 Swift files plus 57 scripts/configuration files, including tests, hidden tracked tooling, and design JSX. Changed 745 files; retained 91 unchanged. Dependencies, generated/vendor output, fixtures, bundled prompts, product copy, and historical documents were excluded. The original 810-file audit was reconciled with main's 28 new or moved paths, including two relocated source files.

The policy in `AGENTS.md` now makes documentation optional for public declarations and test suites. Comments explain non-obvious contracts, invariants, rationale, or workarounds. The audit removes narration and stale history while preserving provider replay signatures, tool-result pairing, persistence formats, cancellation ordering, geometry workarounds, and operational directives. Independent reviews covered every batch and the final integration; findings were addressed.

| Area | Files | Swift comment lines, before → after | UTF-8 bytes, before → after |
|---|---:|---:|---:|
| Chat Swift | 290 | 13,252 → 2,185 | 2,871,550 → 2,147,414 |
| Bible Swift | 283 | 7,246 → 1,355 | 1,862,578 → 1,479,798 |
| Core Swift | 127 | 3,290 → 659 | 562,810 → 397,119 |
| Todo Swift | 54 | 731 → 470 | 206,982 → 190,000 |
| Apps Swift | 16 | 1,358 → 197 | 162,779 → 89,207 |
| Scripts Swift | 9 | 106 → 57 | 33,610 → 30,656 |
| Other code/config | 57 | — | 352,493 → 323,366 |
| Total | 836 | 25,983 → 4,923 | 6,052,802 → 4,657,560 |

Full-line Swift comment candidates fell by 21,060 (81.1%); source size fell by 1,395,242 bytes (23.1%). Counts use identical before/after file sets. Prefix counts exclude trailing/block comments and can include comment-looking strings; all string contents were preserved. No tokenizer was available, so no token-saving percentage is claimed. Source measurements exclude this report and the plan. Detailed per-file dispositions and temporary checkers remain in ignored `.build/comment-audit/`.

## Validation

- All 779 Swift files parse and preserve executable token/syntax trees against the integrated baseline; functional directives and their target statements are unchanged. All 30 Python ASTs, including docstrings, and six JSX/MJS trees match. Twelve YAML configurations retain ordinary values; ten edited embedded shell bodies retain executable content and pass syntax checks.
- Under Xcode 26.4.1, package suites passed with parallel execution, coverage, and warnings treated as errors: Chat 1,136; Bible 881; Core 317; Todo 87 (2,421 total). No test declarations or assertions changed.
- Representative iOS simulator snapshots passed: ChatScreen, MessageList, BibleScreen, BibleChapterReader, AnnotationSheetContainer, MarkdownText, and TodoScreen. Both `Super` and `SuperBible` simulator builds passed on the registered worktree simulator; no signing or recording was performed.
- Script suites passed: simulator tooling 29, visual-testing guards 48, PreviewPilot guards 38, plus hook fixtures. SwiftLint and whitespace checks pass; expanded baseline comparison has no new diagnostics (187 before, 176 after).
- The tracked inventory contains 542 package images and 41 native previews, totaling 583. Audit capture-count delta: **0**. No baseline images, fixtures, resource strings, or operational configuration values changed.

## Existing limitations

Full actionlint reports the same TestFlight ShellCheck SC2046 warning reproduced on `ffbc76d6`; actionlint with ShellCheck disabled passes. The ChatLiveLLM script's missing `toolCallAwaitingConfirmation` switch case was reproduced on the original source during the audit. These unrelated code issues were left unchanged.
