# Animated chat turn focus

**Goal:** Animate the existing move that brings the sent user message to the top. Response updates remain stationary and readers retain control of manual scrolling.

**Approach:** Keep the explicit `ScrollRequest` contract and stable turn layout. Apply a short ease-in-out animation only to explicit target seeks, including the bounded corrections needed when lazy history is materialized. Honor the system Reduce Motion setting with immediate positioning. Avoid animating the transcript's content changes or retaining a scroll target after the move finishes.

**Risks:** An unanimated correction could cut a scroll animation short; repeated corrections could restart it. Lazy targets can be far from the current viewport. A new request or a user drag must supersede an in-flight move. Response deltas arriving during the move must not create new follow behavior. First-message mounts and static snapshot positioning must stay deterministic.

**Plan review refinements:** Serialize animated seeks and evaluate the target only after native scrolling becomes idle. Request a fresh, tagged geometry sample at that point, because the last animation frame's geometry can arrive after the idle callback. Guard measurements by the active request (including sequence) and cancelled/completed status, so old work cannot take back control. Keep initial mounting unanimated. Use an internal optional Reduce Motion override, matching the existing composer convention, to test the read-only system setting. Validate a newer request during a move and visually verify real-drag interruption and the requested user marker while the response grows.

**Validation adjustment:** A UIKit regression first confirmed the old implementation had no intermediate positions. However, this repository's hostless XCTest process does not advance native proxy scroll animations, even with animations enabled and a display-link-driven run loop. Retain its existing final-geometry/streaming regressions with Reduce Motion pinned; test sequencing and callback ordering in a non-observable focus coordinator, and verify actual motion in the running app. `withAnimation` completion also precedes native scrolling completion, so use native scroll phases instead. The review regression for final geometry arriving after idle failed before the tagged-measurement fix and passes afterward.

**Native layout finding:** Long-history sends exposed inaccurate animated proxy seeks while the old `scrollTargetLayout` modifier was present: four corrections each advanced only about 40 points, despite adequate available scroll range. Deferring the correction did not fix it. Remove that redundant target tracking; `ScrollViewReader` still resolves explicit turn IDs. Repeated sends from scrolled-up history then landed in one glide at the expected top inset and stayed there during the response. No persistent position binding or deferred correction task is introduced.

**Validation and delivery:**

- [x] Independent plan review and actionable findings addressed.
- [x] Add eight focus-sequencing regressions covering in-flight geometry, lazy overshoot, late final geometry, cancellation, newer requests, already aligned targets, immediate positioning, and bounded correction. Preserve the existing UIKit streaming/final-position regressions; verify temporal behavior in-app as explained above.
- [x] Implement a 0.3-second ease-in-out animation for explicit moves, native phase sequencing, bounded lazy correction, and gesture cancellation.
- [x] Build and visually exercise sending with the canned debug provider on the dedicated worktree simulator; inspect animation frames and final position. Native drag begins 0.102 seconds after send and cancels the focus; response growth retains that reading position. Two subsequent history seeks land at screen y=127.67, the expected inset below the transcript header.
- [x] Separate code review and actionable findings addressed; final review reports no serious findings.
- [x] Full Chat suites pass: 1,109 tests in 83 suites on macOS; 1,362 tests in 111 suites on the iPhone 17 simulator, Xcode 26.4.1 / iOS 26.4.1 build 23E254a. Existing 581 PNG baselines (247 Chat) remain unchanged; zero added or retired captures. Changed-source SwiftLint and `git diff --check` pass.
- [x] Create draft PR #341 and request Codex review.
- [ ] Follow current-head Codex approval and required CI through verified merge. Monitor every ten minutes while pending.

**CI follow-up:** The package CI command promotes Swift concurrency warnings to errors. Capture the measurement ID by value when constructing the geometry transform, so its Sendable closure does not read main-actor state. This preserves generation-based final measurements without weakening isolation. The narrow correction received an independent review with no findings. CI's exact `swift test --parallel --enable-code-coverage -Xswiftc -warnings-as-errors` command passes all 1,109 tests; the app build passes, and the native send from older history still lands at screen y=127.67.
