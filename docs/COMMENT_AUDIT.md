# Comment Audit

Baseline: `c6a49ba3` (September 9, 2026). Implementation follows the [reviewed plan](superpowers/plans/2026-09-09-COMMENT_AUDIT.md).

## Scope and method

Review all 810 maintained source/configuration files, including 756 Swift files, tests, scripts, workflows, design JSX, and tracked hooks/configuration templates. Exclude dependencies, generated/vendor artifacts, data/image fixtures, bundled prompts, and historical documents. Preserve executable code, runtime strings (including Python CLI docstrings), directives, legal notices, and necessary contracts/workaround rationale.

The initial Swift scan found 26,157 full-line comment candidates among 125,915 lines: 17,832 `///` lines and 8,325 ordinary `//` lines. These prefix counts exclude trailing/block comments and can include strings. Repeat the same method and original file set for the final comparison; measure source bytes separately and claim token savings only with an identified tokenizer.

## Decisions

The root policy no longer requires comments on all public declarations/test suites. Keep comments that explain information the code cannot express; remove restatements and stale history, and shorten useful rationale without losing its constraints.

Calibration and batch results are pending. The per-file inventory and original sources are held in ignored `.build/comment-audit/` during execution.

## Validation

Implementation validation is pending. Expected test/snapshot inventory change: zero; this audit changes comments only.
