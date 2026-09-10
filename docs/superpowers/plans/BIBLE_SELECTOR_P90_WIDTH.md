# Bible selector p90 width

## Approach

Use a 14pt medium book/chapter title and a 106pt preferred content width: the nearest-rank p90 of all 66 titles at 14pt (86.33pt), plus the chapter suffix at that size (19pt), rounded up. Give the passage lower layout priority so it fills extra space and compresses when needed. Preserve app font scaling and Dynamic Type.

Anchor the shell-hosted navigation pill 8pt after the 44pt hamburger reservation, with 12pt outer margins. Normal titles truncate within the available width instead of moving the bar down. At AX4/AX5, probe the anchored layout first and use a full-width fallback only when it cannot fit. Wrapping accessibility content can stack the passage and utility buttons. Minimum button frames and glyph insets accommodate scaled icons without overlap. Preserve the standalone reader's external chapter controls.

## Implementation and risks

- Measure p90 independently in the selector geometry test. Check equal preferred widths, expansion/compression, both font-scaling axes, and long-title stability at 320pt and 375pt.
- Verify AX4/AX5 at 320pt and 1024pt; wide accessibility layouts must retain their hamburger anchor. Keep the existing AX3 captures and add AX5 coverage for the distinct full-width fallback.
- Reuse the history gallery for Song of Solomon and preserve every existing capture. Final inventory: 591 → 593 overall, 259 → 261 Bible, 48 → 50 affected captures.
- Review intentional PNG changes, run affected package and simulator suites, and obtain independent implementation and visual review before pushing.

## Validation results

- The previous 15pt layout reproduced the compact Song of Solomon row jump. The 14pt hard minimum also failed constrained-width checks; the anchored flexible layout passes them.
- Codex review exposed AX5 glyph overlap and clipping. The new AX5 fixture reproduced it; stacked content and growing button frames resolve it. AX3 stays anchored, while compact AX4/AX5 uses the fallback and wide AX4/AX5 passes the single-row geometry budget.
- All 953 Bible package tests, 23 navbar simulator tests, and 30 reader simulator tests pass. All 50 affected captures validate and match the reviewed renders exactly. Scoped SwiftLint, inventory discovery, and `git diff --check` pass.
- Reviewed 39 existing baseline updates plus two new accessibility captures. Normal-size captures did not change during the accessibility follow-up. Independent plan, code, and visual reviews have no remaining serious findings.
- Keep the PR draft and auto-merge disabled until the current revision receives explicit Codex approval and passing CI. Preserve all six required checks, then mark ready, enable auto-merge, and verify merge.
