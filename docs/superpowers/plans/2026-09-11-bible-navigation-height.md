# Bible navigation height implementation plan

**Goal:** Match the combined Bible navigation pill to the shell hamburger's 44-point height while preserving its width-to-height ratio, text proportions, and control order.

**Approach:** Keep the existing selector and glass contents at their natural size, then uniformly fit the complete pill into a maximum 44-point height. The surrounding SwiftUI layout must report the fitted width and height, so the navigation row and reader actually become shorter. Preserve the existing font-scale inputs, accessible labels, disabled states, and actions. Do not change the hamburger or unrelated applet controls.

**Files:** `Packages/Bible/Sources/Bible/UI/BibleNavBar.swift`, a small package-local fitting view/layout if needed, and existing `BibleNavBarSnapshotTests.swift` / affected PNG baselines.

**Risks:** A visual-only transform can leave the old layout height or width behind. Geometry state can cause first-frame jumps or feedback during width probing. Use synchronous measurement with a local `Layout` and a hidden measuring copy, honoring proposed widths for the wrapped fallback. Hide the measurement copy from accessibility and hit testing. Scale the visible contents and corner radius uniformly, then apply glass to the fitted frame: transforming the glass compositor itself misaligns visible controls on the simulator. The fitting wrapper is for this stateless toolbar only.

## Implementation and validation

- [x] Have a review subagent critique this plan and address actionable findings. Measure plain content only; apply glass and its morph identity only to the visible copy. Verify scaling changes and interaction alignment.
- [x] Add a layout regression in the existing suite: no-chevron navigation at 375 points has height 60 (44-point controls + existing 16-point vertical padding), including long names and larger app text. Original implementation fails all six cases (default John is 65.33 points; larger text/long names trigger a second row). Add fitting-view measurement assertions to verify width and height use the same scale factor.
- [x] Implement uniform fitting with a 44-point maximum height before the nav bar performs horizontal fit selection. Preserve selection behavior and existing callback wiring.
- [x] Run `swift test` in `Packages/Bible`: 953 tests passed. Pinned simulator comparison: 26 navigation tests and 30 reader tests passed. Added height, proportion/update, and constrained-width regressions; existing font-scale assertions remain.
- [x] Inspect existing navigation and reader screenshots. Explicitly record 43 intentional baseline updates and rerun comparison. Capture inventory stays 592 after retaining main’s two added accessibility captures; no captures added or removed.
- [x] Have a separate review subagent inspect the changes and address actionable findings. Fixed fallback width proposals; no remaining findings after the final glass correction.
- [x] Build SuperBible and verify live glass: hamburger and passage button both report y=66, height=44. Open the passage picker, change chapter, navigate back/forward, open actions, start narration, and stop it. SwiftLint and diff checks pass.
- [ ] Open a draft PR using the repository template with test results and visual evidence. Monitor CI and Codex review every 10 minutes; after current-revision approval and passing checks, mark ready, enable auto-merge, and verify the merge.

## Integration with anchored navigation

Preserved main’s p90 preferred title width, left anchoring, and accessibility fallback layouts. Fit each accessibility candidate before horizontal selection so an already fitting row does not become a tiny stacked pill. The independent reviewer found no remaining issues in this integration.
