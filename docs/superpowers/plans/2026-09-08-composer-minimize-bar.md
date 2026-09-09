# Chat composer drag handle

## Approved design

The user approved the compact flat handle in Simulator and requested auto-merge. This supersedes the earlier full-width bar and chevron comparisons.

- Center a 36×4.5pt glass capsule below the model selector and context meter. Share the top handle's width, height, and continuous capsule shape.
- Use the model selector's `SuperGlass` treatment without an additional fill, border, or shadow.
- Use 1.5pt above the bar, a 12pt layout slot, and 2pt capsule bottom padding. The metadata row remains 28pt; the footer is 40pt. The composer is 8pt shorter than the earlier published full-width version.
- Preserve a 44pt transparent touch region and matching accessibility frame. Shift the invisible target 16pt upward, compensating the visible bar position, so it remains above the software keyboard; give the metadata controls hit-test precedence where their bounds overlap. Tap minimizes and dismisses keyboard focus; drag feeds the existing overlay callbacks and snap physics used by the top handle. Preserve drafts, references, recording, and streaming.

## Implementation

1. Share the bar geometry and global-coordinate drag factory through `ChatDragHandle`. Preserve its zero-distance gesture start; use a 5pt threshold on the lower handle to distinguish a drag from a tap.
2. Forward `ChatScreen`'s drag callbacks into `ChatComposer`. Make the lower drag exclusive with tap-to-minimize. Retain the gesture host while the footer fades, with hit testing maintained for an active drag. Expose the accessible minimize action only when the bar is visible.
3. On normal release, forward final and predicted translation once. On cancellation/disappearance, consume the last translation once and settle without projected velocity. Hosts without `onMinimize` retain their original layout.
4. Update the existing composer dimension inventory and guard. Reuse the 21 native composer cases and nine overlay fixtures; no new captures or retired identities. Keep all 623 repository captures and current renderer pins.

## Risks and validation

- Inspect light/dark, maximum font scale/XXL, references, minimized, mid-morph, and keyboard layouts on the registered iPhone 17, Xcode 26.4.1 / 17E202, iOS 26.4.1 / 23E254a.
- Verify visible-bar tap, wide/lower touch region, adjacent model selection, upward drag, keyboard-visible downward drag, direction reversal, cancellation, and hidden accessibility. With the keyboard closed, the physical space below the lower bar limits downward travel; short drags may snap back under the shared physics, while tap minimizes immediately.
- Run the full Chat macOS suite, the relevant existing Simulator snapshots, PreviewPilot guards, app build, SwiftLint, and diff checks. Compare repository baselines first; inspect intended differences, explicitly record only the approved changes, and rerun default comparisons. Do not widen tolerances or alter renderer settings.
- Obtain independent plan and implementation review, address serious actionable findings, and repeat affected QA. Gesture lifecycle is manually verified on Simulator because there is no app-target UI test harness; existing snap/overlay tests cover the shared resolver.

## Delivery

Update draft PR #346 with the approved design, reviewed PNG changes, and exact QA results. Request Codex review of the resulting head. Check CI and Codex together every ten minutes, fixing failures and findings. Only after explicit current-head Codex approval and passing applicable CI, mark ready and enable auto-merge with the protected checks intact. Disable auto-merge before any subsequent push and renew both gates for each revision. Verify the eventual merge, then stop the existing heartbeat. Retain this worktree and its registered Simulator.

## Verification evidence

- The approved prototype builds on the registered Simulator. All 1,103 Chat tests and SwiftLint/diff checks pass on the restored source.
- Manual verification covers tap-to-minimize, reopening and upward drag to expanded, keyboard-visible downward drag with keyboard dismissal, draft preservation, down-and-back reversal, and Home interruption recovery. The hidden accessibility action is absent when minimized.
- Latest accepted image: `.build/ComposerPrototype/evidence/compact-handle-padding-final.png`. Existing native captures previously verified the 24px reduction at 3× for expanded cases and unchanged minimized/mid-morph dimensions. Final repository baseline results are recorded below; exact-head remote checks remain merge gates.

Independent final review identified a text-sized accessibility representation and a keyboard-covered lower target edge. The representation now has an explicit 44pt frame. Simulator confirmed the original keyboard-visible target was y511–555 while the keyboard began at y540; tapping y553 did not minimize. Move only the target upward 16pt, compensate the bar padding to preserve its exact visible position, and prioritize metadata controls over the overlapping region. Recheck the corrected top/bottom edges, visible bar, model picker, drag, and hidden accessibility, then rerun baseline comparisons without recording.

Final source review is clear after the invisible-target correction. Simulator reports a 338×44pt target at y495–539 with keyboard open (keyboard begins y540); tapping (201,537) now minimizes. Its new top edge also minimizes at (220,796) in semi-expanded chat. Model-picker overlap taps remain correct at default scale and with the longer Debug (mock search) label at 120% scale; original settings were restored. Accessibility frame/hidden-action inspection passed; native VoiceOver interaction itself was not exercised.

The final 1,103-test Chat suite, app build, and lint/diff checks pass. Native recording changed nineteen composer PNGs; fourteen unrelated Settings rounding-only changes were restored. The fresh default 41-image native comparison passes after the touch correction, confirming unchanged approved visuals (`.build/PreviewPilot/run-iveoz_2s/`). Chat recording changed seven overlay PNGs, retained the other 237 baselines, and validated all 244 images; the final default comparison passed all 244 captures across 26 selected suites (`.build/approved-chat-final-compare/`). PreviewPilot's 38 guard tests pass. Inventory stays 623→623.

Independent final source and baseline-scope review found no remaining serious actionable findings. Both app builds pass on the final touch correction. The user's auto-merge authorization is active; publish the final source, inventory, and 26 reviewed PNGs, then request exact-head Codex review and resume the existing ten-minute delivery heartbeat.
