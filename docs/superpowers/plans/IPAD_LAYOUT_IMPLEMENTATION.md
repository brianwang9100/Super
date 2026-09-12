# SuperBible iPad layout implementation plan

**Goal:** Implement the six updates in [the iPad audit](../../SuperBible/IPAD_AUDIT.md) while preserving the existing iPhone layouts and interactions.

**Architecture:** Keep the existing applet composition and Chat overlay. Use a shared 760-point maximum column width, including each surface's existing horizontal padding. Window geometry, rather than device identity, determines available space. Use SwiftUI's actual container corner insets to reserve space for system window controls.

**Tech stack:** SwiftUI, Core/Chat/Bible packages, Swift Testing, existing Point-Free visual fixtures; pinned Xcode 26.4.1 and iOS 26.4.1.

## Constraints and risks

- No persistence, provider, persona, navigation-state, or dependency changes. No persistent sidebar or side-by-side reader/Chat mode.
- Preserve current iPhone spacing, font scaling, glass treatments, sheet conventions, focus handling, and drag/scroll reducers. Do not alter existing snapshot tolerances.
- The full outer Chat geometry continues to own vertical anchors, safe areas and keyboard handling; width stays stable through the morph. Expanded Chat must cover the backdrop even outside its bounded content column.
- The shell's window-control reserve must update on resize and clear the hamburger and adjacent applet controls together. Full-screen iPhone must receive no extra inset.
- The disclaimer must initially show a reachable acknowledgment in a short window at 120%; its text may scroll. Retain its current layout whenever it fits.
- Use the existing worktree; shared shell changes require builds of both app schemes. Tests and simulator mutation use the worktree's dedicated devices.

## Task 1: Shared column and window chrome

Files: new `Packages/Core/Sources/Core/Theme/SuperContentLayout.swift`; `App/Shell/AppShell.swift`.

- [x] Introduce `public enum SuperContentLayout { public static let maximumColumnWidth: CGFloat = 760 }` for the shared reader/Chat/list alignment.
- [x] Wrap the shell content in a geometry reader and reserve `max(geometry.containerCornerInsets.topLeading.height, geometry.containerCornerInsets.topTrailing.height)` at the top using `safeAreaPadding`. Read geometry outside the adjusted content so resizing cannot create a feedback loop. Keep sheets outside this adjustment.
- [x] Bound `ComposerAccessoryFlank` after its existing 20-point horizontal padding and before its full-size bottom alignment: `.frame(maxWidth: SuperContentLayout.maximumColumnWidth)`.
- [x] Reproduce and verify actual window controls in the 375 × 486 floating window, then full-screen iPad and iPhone. App-target manual QA is the documented exception to package snapshots.

## Task 2: Reader and lists

Files: `BibleChapterReader.swift`, `BibleScreen.swift`, `BookmarksScreen.swift`, `ChatsScreen.swift`; their existing screen snapshot suites.

- [x] Keep the reader's full-width ScrollView and scrolling callbacks. Cap its padded chapter VStack at 760 and then center it using an outer infinite-width frame. The footer stays inside this column.
- [x] Bound the Bible navigation row and toast contents to the same width while retaining the full-width navigation gradient. Preserve standalone preview behavior and adaptive toolbar wrapping.
- [x] Bound the Bookmarks content VStack, keeping six scrollable slots and current 18-point margins.
- [x] Bound the Chats content and its top-trailing New Chat overlay together so title, search, list and add action share a column. Keep the screen background full-width.
- [x] Add one landscape reader capture, one narrow-window enlarged reader capture, one landscape Bookmarks capture, and one landscape Chats capture to existing suites. Compare existing phone captures unchanged.

## Task 3: Chat overlay

Files: `ChatOverlay.swift`, optionally `ChatScreen.swift`; existing Chat overlay snapshots and geometry tests.

- [x] Set the rendered ChatScreen width to `min(geo.size.width, SuperContentLayout.maximumColumnWidth)` before the existing outer full-width/keyboard-height frame. Keep the same width at all progress values.
- [x] Fill the entire outer backdrop with the theme background as Chat reaches full expansion, including safe areas, so only the conversation column is bounded at that endpoint.
- [x] Keep composer, transcript, header, scroll-to-bottom control and drag handles together in the bounded screen. No changes to anchor math, focus/drag reducers, transcript follow-scroll or reference handoff.
- [x] Add contrasting-backdrop landscape captures for minimized, semi-expanded and expanded Chat; compare existing phone fixtures and geometry tests. Verify native semi-expanded side-margin dismissal and the expanded background; review the existing expanded-state applet hit-testing cutoff.
- [ ] Complete the full two-device interaction matrix for both drag handles, transcript edge, references and software keyboard. Completed checks and remaining limits are recorded below; the user accepted the current iPad result and requested a PR.

## Task 4: Annotation acknowledgment

Files: `AnnotationDisclaimerSheet.swift`, `BibleStudySheetsModifier.swift` if presentation adjustment is necessary, and `AnnotationDisclaimerSheetSnapshotTests.swift`.

- [x] Add short-window 120% layout regression coverage before changing the sheet; preserve current default/XXL fixtures. Measure the actual native medium-detent content height in the 375 × 486 window, and exercise that height plus a 300-point stress fixture.
- [x] Use `ViewThatFits(in: .vertical)` to retain the original fitting layout, with a compact fallback that scrolls explanatory content and reserves the acknowledgment outside the scroll view. Keep the same copy and dismissal/persistence callback.
- [x] Verify the real medium-detent presentation initially and after resizing; adding a second detent alone does not fix initial clipping.

## Task 5: QA, review and delivery

- [x] Have a review subagent critique this plan before implementation; address actionable findings.
- [x] Run affected Core, Bible and Chat package suites with `swift test` and relevant serialized simulator visual/interaction suites. Explicitly record and inspect only new/intentional baselines, register their dimensions in `Scripts/VisualTesting/package-inventory.json`, and report inventory delta. Existing iPhone PNG changes require investigation.
- [x] Build Super and SuperBible. Verify iPad portrait, landscape and short windows, enlarged text, native acknowledgment resizing, narration follow-scroll, local annotation generation and nested annotation presentation. Verify iPhone portrait and rotation policy, reading/navigation, keyboard with canned Chat, Chat minimization, and Chats search. Existing default/enlarged phone snapshots compare unchanged.
- [ ] Complete exhaustive secondary interaction checks, including short-window voice picker and share cancellation. These remain documented spot-check limits for this starting-point PR.
- [x] Run a separate implementation review, resolve findings, and repeat affected checks.
- [x] Update the audit with implementation, validation results and committed evidence links.
- [x] Create draft PR #372 with the repository template and local results.
- [ ] Monitor applicable CI and Codex review. After explicit Codex approval of the current revision and passing CI, mark ready, enable auto-merge with required checks enforced, and verify merge.

## Progress

- Audit and user spot-check build completed at `67f5b2be`; no production changes at plan creation.
- Workspace is already an isolated linked worktree with detached HEAD. Create a `codex/` branch before delivery.

- Plan reviewed by audit_review: addressed sheet viewport measurement, contrasting Chat backdrop/hit-testing, and iPhone landscape coverage.

- Both app targets support portrait only on iPhone (project.yml); hardware rotation was tested and correctly keeps the app in portrait. iPad retains all four orientations. No orientation policy was changed.

- Implementation and independent review complete. Local results: 2,436 package tests, 189 affected simulator tests, 48 visual-inventory guard tests, and both app builds passed. Eight new captures bring the tracked inventory from 593 to 601; all existing phone PNGs from main are unchanged. See the audit for the manual checks and remaining limits.

- Integrated main PR #371 after CI identified stale navigation expectations in the two new reader captures. Reproduced the two mismatches locally, inspected both renderings, explicitly refreshed only those new captures, and passed all 73 affected Bible simulator tests plus 953 package tests. Existing phone baselines from main are unchanged. The new total includes main's two navigation accessibility captures; integration review found no serious actionable issues.
