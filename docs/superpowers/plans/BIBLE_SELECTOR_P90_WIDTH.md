# Bible selector p90 width

## Approach

Reduce the book/chapter title from 15pt to 14pt medium. Use the nearest-rank p90 of 66 title widths at that new size (86.33pt), plus the 14pt chapter suffix (19pt), rounded up to a 106pt preferred content width. The user superseded the hard minimum with low hugging/compression resistance: the passage fills extra space and compresses when needed.

Anchor the shell-hosted navigation pill 8pt after the existing 44pt hamburger reservation, retaining the shell's 12pt outer margin. Give the passage lower SwiftUI layout priority than history/narration/actions and remove its horizontal fixed sizing. Long titles truncate within the available width; accessibility text can wrap inside the anchored pill. Preserve app font scaling and Dynamic Type. The standalone reader's optional external chapter-step controls retain their existing adaptive arrangement.

Independent plan reviews found no gaps in the sizing approach. The anchored-layout review identified missing shell-hosted accessibility coverage; add one focused capture while retaining the standalone case.

## Implementation

- Update the geometry test in `BibleNavBarSnapshotTests.swift` to measure sorted catalog widths at 14pt and use index `ceil(0.9 * count) - 1`. Verify the ideal width, equal widths across titles, and fitting at both narrower and wider proposals. Add Song of Solomon to compact-width coverage (320pt and 375pt) and the existing history gallery without adding a capture.
- Use the measured p90 in `BibleNavigationSelector.swift`; make the passage frame flexible and give it low layout priority. In `BibleNavBar.swift`, use the anchored available-width row for the shell-hosted form, keeping fixed-size utility buttons and accessibility reflow.
- Inspect and explicitly refresh only affected existing navbar and reader PNG baselines. Add one shell-hosted accessibility capture at 320pt, accessibility3, and app scale 1.2; existing accessibility captures exercise only the standalone branch. Retain all existing captures. Inventory: 591 → 592 total, 259 → 260 Bible, 48 → 49 affected captures.

## Risks and validation

- Confirm long titles cannot shift the shell-hosted toolbar to another row; inspect the leading/trailing edges in the history gallery. Keep compact long-name geometry assertions and inspect existing narrow accessibility and standalone reader reflow captures.
- Confirm the width geometry test fails against the old constant, then passes with the new one. Preserve scaling assertions.
- Run `swift test --package-path Packages/Bible`, the navbar and Bible screen simulator suites on the worktree's pinned device, scoped SwiftLint, and `git diff --check`.
- Obtain independent plan and implementation reviews, create a draft PR with results and baseline count, and follow repository CI/Codex review and merge requirements.

## Validation results

- The original 15pt layout failed the Song of Solomon compact-row regression. The 14pt hard minimum also failed at 320pt and rejected both narrower and wider selector proposals. The final anchored/flexible layout passes these geometry checks and the p90/scaling assertions.
- Bible package suite: 953 tests passed. Scoped SwiftLint and diff whitespace checks passed. Independent implementation review found no serious actionable findings.
- Reviewed and recorded 39 existing PNG updates (13 navbar, 26 reader) plus one new anchored accessibility capture. All 49 recorded baselines match the inspected captures exactly. Independent visual review found no serious regressions.
- Final pinned-simulator comparison passed: 21 navbar tests and 30 reader tests. Inventory discovery and image validation passed; capture count is 592 overall / 260 Bible.
- Draft PR and CI/Codex review monitoring follow the repository delivery workflow; all six required branch-protection checks were verified present.
