# Deferred Settings capture stability

This tranche migrates the four Settings cases retained by PR #333: appearance light, appearance dark, full-height appearance light, and data exporting light. Argos increases from 37 to 41 captures; legacy PNGs decrease from 584 to 580, including Settings 76→72. The [inventory](../Scripts/PreviewPilot/settings-inventory.json) maps each replacement to its former assertion/image. Dark exporting, tall-dark appearance, XXL sentinels, and all other unmigrated cases remain in the legacy suite and its four CI jobs.

## Causes and fixes

The native renderer chose extended-range 16-bit output automatically. Earlier appearance runs differed in low bits, including a one-level 8-bit difference at a theme-card edge. The test-only renderer patch now sets `UIGraphicsImageRendererFormat.preferredRange = .standard` explicitly for both target and window capture paths. Output is standard-range 8-bit; no image masks, custom comparison tolerances, post-capture blurring, or UI substitutions are introduced. Apple documents that [preferredRange controls the output pixel format](https://developer.apple.com/documentation/uikit/uigraphicsimagerendererformat/preferredrange).

Standard range alone happened to produce two matching full runs, including the spinner. A deliberate elapsed-time regression then failed: the real `ProgressView` differed when sampled after a 100ms initial wait and another 650ms. Disabling UIView and SwiftUI transaction animations was already part of the renderer, but did not stop this explicit repeating animation.

The renderer now pauses the hosting layer's clock at local time zero before mounting its content, then advances it to 0.25 seconds when layout settles. The real spinner stays visible at a deterministic phase; no wall-clock timestamp is used. The capture-owned view is discarded normally. This uses [Core Animation layer timing](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/AdvancedAnimationTricks/AdvancedAnimationTricks.html) exclusively in the test target. Production app code, animations, package dependency graphs, and authentication are unchanged.

## Baseline impact and visual review

Standard range intentionally changes the existing 37 PNGs. Old/new decoded channel differences reached 14/255; these are rendering-contract changes, not production UI changes. Independent review of representative composer states, dark/light recording controls, mid-morph/pills, UIKit fonts, and all four restored Settings cases found no color clipping, banding, lost glass, typography fallback, layout shift, or content loss. Subtle warm/accent shifts are visible and require Argos review. The tall appearance image retains all eight theme cards, and both selected-theme states, slider thumbs, haptics, and export spinner remain visible.

Adding the fixed clock after standard range changed only the exporting image. Existing capture dimensions and identities are unchanged; the tall image remains 1206×4020 pixels. Only the three verified appearance methods and the exporting-light assertion are retired with their four PNGs. The exporting-dark method name and PNG remain intact.

## Local validation

Pinned Xcode 26.4.1 / 17E202 and iOS 26.4.1 / 23E254a on the registered worktree iPhone 17 simulator. Select the installed stable toolchain with `DEVELOPER_DIR='/Applications/Xcode 26.app/Contents/Developer'` when the machine default points to Xcode 27 beta.

- Standard-range experiment: `.build/PreviewPilot/run-4uhaacpz/` and `run-13nyyupm/` matched all 41 PNGs, but the delayed-spinner negative control failed in `run-qtxsz80h/`.
- Fixed clock: `run-vwpc86mr/` and `run-2gmtruca/` exported **41/41 byte-identical PNGs**, including all restored cases. Final run passed **21 Python guards and 47 iOS capture/regression tests**. The new test checks repeatability across different elapsed times, 8-bit output, and nonblank spinner ink on a white background; capture callbacks have a five-second timeout. The tall-gallery guard rejects viewport-height cropping.
- Chat `swift test`: **1,117 tests in 86 suites passed**.
- Retained Settings simulator suite: **70 tests passed**, preserving 72 legacy PNGs.
- Super and SuperBible Release builds and isolation audits passed with no preview/vendor runtime findings. Independent final code review found no material issues; Argos workflow actionlint passed. Patched upstream source and all other changed files receive whitespace validation separately because unified-diff context lines in `renderer.patch` intentionally contain a single space.

The live Argos build must add exactly the four inventory names, remove none, and show only inspected renderer-related changes among the prior 37. Inspect original CI PNGs rather than JPEG-converted image-delivery URLs when making pixel comparisons. Baseline approval, all applicable CI, and explicit current-revision Codex approval precede guarded auto-merge. No required checks are weakened, and Git history is not rewritten.
