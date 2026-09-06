# Selection pill motion and independent chapter controls

## Approach

- Keep the selection pill available at the chapter footer while hiding the redundant floating chapter arrows independently.
- Rename the generic accessory suppression predicate to describe edge-button visibility. Bible supplies footer visibility without consulting selection state; Chat renders and animates the edges, while the shell continues to own the whole row's placement and chat-expansion fade.
- Give selection insertion/removal an explicit opacity transition using the same `SuperMotion.chrome` token as the chapter arrows: 0.4 seconds in, 0.6 seconds out, and the existing 0.2-second Reduce Motion fade. Changes to the selected citation must not restart the transition.
- Preserve edge layout space and disable hit testing/VoiceOver for hidden arrows. Retain the persistent upward chevron and content clearance.

## Risks

- Parent sheet animation transactions must not shorten the pill fade.
- Footer and selection changes can arrive together; each control must retain its own visibility and animation.
- Hidden arrows must not intercept the chapter footer or remain accessible.
- Both app targets compile the shared shell, although only SuperBible injects accessory controls.

## Validation

- Review this plan before implementation and obtain independent code reviews afterward.
- Add light/dark snapshots for a retained selection with hidden edges; preserve existing edge/canon-end/long-selection snapshots. Demonstrate the visibility regression against the old renderer. Reduce Motion has identical settled pixels and its environment value is read-only, so verify that setting manually on the simulator.
- Run the affected Core, Bible, and Chat package suites, the accessory simulator snapshots on the registered iPhone 17 / CI-pinned runtime, and build both app schemes.
- On the worktree simulator, select at the footer, dismiss/reopen the actions, add a verse, and clear selection. Verify that arrows remain hidden at the footer, return above it, and the pill uses the same fade cadence, including Reduce Motion.
- Open a draft PR, monitor CI and Codex review, and enable auto-merge only after approval and passing checks for the current revision.

## Results

- Plan and independent architecture/behavior reviews found no actionable issues.
- Core: 314 tests passed. Bible: 714 passed. Chat: 1,066 passed.
- All 10 accessory snapshot methods passed on the registered iPhone 17, Xcode 26.4.1 (17E202), iOS 26.4.1 (23E254a). Both new light/dark snapshots failed against the old renderer, then passed with the fix. Existing baselines remained unchanged.
- Both SuperBible and Super simulator builds passed. Targeted lint passed with only three pre-existing shell warnings; diff whitespace checks passed.
- Live QA confirmed footer selection persists through dismissal, additional verse taps leave the sheet closed, the pill reopens it, clearing fades the pill out, arrows return above the footer, and opening chat hides the whole accessory row. Normal and Reduce Motion were exercised; the simulator's original Reduce Motion setting was restored.
- Accessibility QA found that the shell's parent visibility flag exposed flattened hidden children. Explicit containment now keeps the edge visibility independent: hidden arrows are absent from the accessibility tree, the pill actions remain separate, and chat expansion hides the container.
- A simulator recording shows the pill's opacity fading over approximately 0.6 seconds. The implementation uses the same shared reveal/hide tokens as the arrows, with the existing Reduce Motion fallback.
