# Follow-up: restore the SidebarDrawer slider-independence invariant

**Status:** deferred from PR #136 (SuperTypography PR B — shell + Chat). The fix below
is written and verified-correct; it could not land in #136 because re-recording the
affected snapshot baselines was blocked by a local simulator font-rendering failure
(documented at the end). This spec is the carry-over so a follow-up PR can apply the fix
and re-record on a healthy environment.

## The regression

Pre-`SuperTypography`, the **Chat sidebar drawer was deliberately slider-independent**:
the chat font-scale slider stayed scoped to the message list, and the drawer chrome
(wordmark, version mark, section labels, applet rows, and chat rows) rendered at fixed
sizes. `ChatRow` / `SeeAllChatsRow` carried an explicit documented invariant:

> Row title intentionally does **not** track the chat font-scale slider — it's drawer
> chrome, not reading content, so the slider stays scoped to the message list.
> `@ScaledMetric` still composes Dynamic Type on top of the base.

The PR B typography migration mechanically routed every sidebar surface through the
`typography.*` accessors. Those accessors **fold `fontScale` into every size**
(`size * fontScale` inside `SuperTypography.spec`), so the whole drawer now scales with
the slider — silently reversing the invariant. The migration also re-recorded the
`sidebar_font_scale_max_{light,dark,sepia}` baselines, so the regression passed CI
instead of being caught (a re-record-to-pass).

This was flagged by the PR #136 code review (Finding 1). It is confirmed real, not a
documentation nit.

### Evidence the rows genuinely scale now

Rendering `fontScaleMaxRowsScale (light)` (harness injects
`.superTypography(.make(.serif, fontScale: 1.20))`) under two source variants, on the
same simulator, isolates the row change independent of any font-rendering issue:

- migrated code (`typography.font(size: rowTitleBase)`): `sidebar_font_scale_max_light.png` = **261983 bytes** (rows at `17 * 1.20`)
- fixed-row code (`.system(size: rowTitleBase)`): same snapshot = **246778 bytes** (rows at `17`)

The byte delta is the rows (and other system-font chrome) growing by 1.2×.

## What shipped in #136 (so this PR knows the starting state)

- The migrated (scaled) behavior is **accepted as-is** in #136 — no source change to
  `SidebarDrawer.swift`.
- The three fontScaleMax tests were **relabeled honestly** so they no longer claim the
  invariant they no longer hold:
  - `fontScaleMaxRowsUnchanged{,Dark,Sepia}` → `fontScaleMaxRowsScale{,Dark,Sepia}`
  - helper `verifyFontScaleMaxUnchanged` → `verifyFontScaleMax`
  - `@Test` display names → "font scale max — sidebar scales with slider (known regression, see spec)"
  - doc comments updated to describe the regression and point here.
- Baselines unchanged (the relabel is name/comment only).

## The fix (verified correct for the rows)

Restore slider-independence for the two **system-font** rows by bypassing the
fontScale-folding accessor. Exact diff applied & validated during #136:

`Packages/Chat/Sources/Chat/UI/SidebarDrawer.swift`

- `ChatRow`: remove `@Environment(\.superTypography) private var typography` (becomes
  unused); restore the title font to
  `.font(.system(size: rowTitleBase).weight(isActive ? .medium : .regular))`; restore the
  "intentionally does **not** track the slider" doc comment, adding a note that it uses
  `.system(size:)` *because* a `typography` accessor would fold `fontScale` in.
- `SeeAllChatsRow`: same removal; restore `.font(.system(size: rowTitleBase))` for the
  title and `.font(.system(size: 11, weight: .medium))` for the chevron; restore the
  mirrored doc comment.

`@ScaledMetric(relativeTo: .subheadline) rowTitleBase` stays — it carries OS Dynamic Type
without the app slider, which is the desired behavior.

### Open design question for the wordmark + mono labels

The rows are clean to fix because they use the **system** face. The wordmark
(`typography.display(36)`) and version/section labels (`typography.mono(11)`,
`typography.font(.caption2)`) use the **brand faces**, which are coupled to `fontScale`
in the accessor — there is no "brand face, but ignore the slider" API today. Decide one of:

1. Accept that the wordmark/labels scale with the slider (only restore the rows). Simplest;
   matches the original *row* invariant literally but not the broader drawer-wide one.
2. Add a slider-independent path to `SuperTypography` (e.g. a `relativeTo`-style flag that
   also opts out of `fontScale`) and route the wordmark/labels through it. Restores the
   full drawer-wide invariant but touches Core (shared with Bible/Todo).

Pre-migration, **none** of the drawer scaled with the slider, so option 2 is the faithful
restoration; option 1 is the minimal one. Recommend confirming intent before implementing.

### Re-record after fixing

`sidebar_font_scale_max_{light,dark,sepia}` must be re-recorded (rows shrink back to fixed;
if option 2 is taken, the wordmark/labels shrink too). All other sidebar baselines are at
`fontScale == 1.0` and are unaffected. CI trio: iPhone 17 / iOS 26.4 / Xcode 26.4.1,
`SNAPSHOT_RECORD` via `launchctl setenv`, scheme `Chat`.

## ⚠️ Environment blocker that stopped #136 (fix this first, or re-record elsewhere)

Re-recording was impossible because the **local simulator rendered the bundled brand
fonts (Instrument Serif Italic / JetBrains Mono) as the system-sans fallback.**
Symptom: `CTFontManagerRegisterFontsForURL(..., .process, ...)` succeeds and
`UIFont(name: "InstrumentSerif-Italic", size: 26)` is non-nil (the harness's
registration assertion never fired), yet SwiftUI draws fallback glyphs. It rendered
correctly earlier in the same session, then degraded.

Ruled out (none fixed it):
- `simctl erase` the device; reboot the device; boot a second iPhone 17 sim
- restart the CoreSimulator service (`killall com.apple.CoreSimulator.CoreSimulatorService`)
- kill the in-sim font daemon (`fontservicesd` inside the iOS 26.4 runtime) + host `fontd`
- clear the host font cache (`atsutil databases -removeUser`)
- `~/Library/Developer/CoreSimulator/Caches/` was already **empty**
- clean DerivedData rebuild (`rm -rf` the project's DerivedData)
- confirmed the `.ttf` is valid (71592 bytes, real TrueType, not an LFS pointer) in both
  source and the built `Core_Core.bundle`
- ruled out a concurrent worktree session contending the sim (failed in an idle window too)

The only untried full reset is a **machine reboot** (rebuilds every font cache at boot) —
likely fix, not guaranteed since the daemon restart alone didn't help. Alternatively,
re-record on a machine whose simulator renders the brand fonts (e.g., CI is healthy — its
`ios-snapshot-test` passes against the serif baselines). Verify a healthy environment up
front: run any one sidebar snapshot and confirm the "Super" wordmark renders in Instrument
Serif **Italic**, not upright system sans, before trusting a re-record.
