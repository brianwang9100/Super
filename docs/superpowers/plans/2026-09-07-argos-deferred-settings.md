# Stabilize deferred Settings captures

## Approach

Continue from merged PR #333. Investigate the retained appearance light/dark/full-height light and exporting light scenarios independently. Existing evidence shows low-bit native image variance around rendered edges and a changing spinner phase. Preserve app behavior, exact layout/state coverage, pinned toolchain, and existing legacy coverage until replacements are verified.

1. Review this plan and renderer timing/color paths. Use the prior two 41-image exports as failing evidence; add focused renderer regression probes for any new rendering behavior.
2. Reintroduce the four preview declarations/inventory entries for controlled experiments. Test one renderer hypothesis at a time: deterministic animation sampling for the spinner, and an explicit standard image-rendering color range for low-bit variability. Prefer capture-only changes over production UI substitutions. Do not mask controls, remove their content, loosen global comparison thresholds, or edit cached renderer code outside the tracked patch/integrity workflow.
3. Select a fix only after reproducing the failure and demonstrating stable captures. If a renderer change affects existing captures, inspect all affected images and record the intentional baseline changes; do not assume existing images remain identical.
4. Validate full captures twice (41 total if all four succeed), inspect all four against legacy references, preserve all eight theme cards in the tall case, and assert the spinner is visible in the exporting state. Run affected package tests, retained Settings simulator tests, renderer guards, and Release isolation checks as appropriate.
5. Retire only verified replacements and their legacy assertions/PNGs; final target is Argos37→41 and legacy584→580. Retain dark exporting and unmigrated cases. Document findings and exact count changes.
6. Independent final review, draft PR, CI/Argos baseline inspection, current-revision Codex approval, guarded auto-merge, and verified merge. Monitor CI/review together every10minutes. No Git-history rewriting.

## Risks

Freezing a parent layer may affect implicit animations or glass and can hide the spinner if sampled before it is installed. Standard color range could quantize wide-color output and affect all baselines without curing GPU edge variation. Both are hypotheses, not preapproved fixes. Require evidence and isolated negative controls before adopting either. If these approaches do not solve the issue, investigate further rather than silently dropping visual coverage.

## Review and experiment results

Independent plan review approved the experiments and required a nonblank spinner assertion plus separate full capture processes. Standard range alone produced two identical 41-image runs, but a targeted 100ms/650ms elapsed-time spinner control failed, proving accidental phase agreement was insufficient. The capture-owned layer clock fixed that control without hiding the spinner; it changes only exporting when compared with standard-range-only output. Two full fixed-clock runs then produced 41 byte-identical images. Visual review found subtle intentional color changes from standard range, with preserved layout, typography, glass, all eight theme cards, and actual spinner content. See `docs/ARGOS_SETTINGS_STABILITY_RESULTS.md` for validation and delivery evidence.
