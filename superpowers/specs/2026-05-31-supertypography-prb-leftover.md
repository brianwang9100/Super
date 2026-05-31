# PR B (SuperTypography — Shell + Chat): leftover work to finish & ship

**Status:** WIP on branch `typography-b-shell-chat`. Code complete; snapshots re-recorded
but **not yet verified**. This session got into a bad state (stale simulator UDID, context
bloat) and is being abandoned. Start fresh from this spec.

This is **PR B** of the 4-PR plan in
`.claude/plans/fluffy-bouncing-wigderson.md` ("Centralize typography in Core:
`SuperTypography`"). PR A (Core foundation) already merged as #125. PR C (Todo) and PR D
(Bible) come after.

## What PR B is

Shell wiring + Chat migration onto Core's `SuperTypography`:
- Inject `.superTypography` in `AppShell` at the same boundaries as `.superTheme` /
  `.superFontScale`; rebuild it in the existing `onChange` for both `fontScale` and
  `typography.id`.
- Add a `"typography.id"` `SettingRecord` (default `.serif`) to ChatSettings.
- Fold `ChatAppearance`'s font responsibilities into `SuperTypography`.
- Migrate every Chat view off hand-written `.font(.custom/.system(...))` onto
  `typography.display/font/mono(...)`.
- Re-record Chat snapshots for the intentionally-changed surfaces.

## Current git state (branch `typography-b-shell-chat`)

**Committed** in WIP commit `daf6a6a` ("PR B (WIP): wire SuperTypography through shell +
migrate Chat views"):
- `App/Shell/AppShell.swift` — `.superTypography` wiring + onChange rebuild.
- All Chat Settings files (`ChatSettings.swift`, `ChatSettingsStore.swift`,
  `SettingsViewModel.swift`, all `*PaneView`/`*DetailView`, `ContextMeter.swift`, etc.) —
  `typography.id` setting + view migrations.
- `ChatAppearance.swift` — folded into `SuperTypography`.
- Chat message views (`MessageListView`, `AssistantBubble`, `AssistantActionRow`,
  `UserBubble`, `ReasoningTrace`, memory panes) — migrated.
- A batch of re-recorded snapshot PNGs from an earlier pass.

**Uncommitted in the working tree** (THIS is what still needs committing — see below):
- 8 source files with **`@ScaledMetric` restored** (decision ④ — Dynamic Type fix):
  `ChatHeader`, `Messages/UserBubble`, `VerseReferencePill`, `ChatsListRow`,
  `ChatsEmptyState`, `ChatsScreen`, `ChatComposer`, `SidebarDrawer`.
- 4 snapshot test harnesses with **`.superTypography(.make(...))` injected** (decision ②):
  `ChatComposerSnapshotTests`, `ChatHeaderSnapshotTests`, `MessageListSnapshotTests`,
  `SidebarDrawerSnapshotTests`.
- ~80 re-recorded PNG baselines under
  `Packages/Chat/Tests/ChatTests/UI/Snapshots/__Snapshots__/`.

> NOTE: by the time you read this, the new session should commit & push the working tree
> (see "Immediate" below). If `git status` is already clean and the branch is pushed, skip
> to "Verification still required".

## Two design decisions already made (do NOT re-litigate)

- **④ Dynamic Type fix = "Keep `@ScaledMetric` in views."** Core's `SuperTypography`
  resolver (`spec()`) **drops `relativeTo` on the system-font path** — so
  `typography.font(size:relativeTo:)` does NOT give OS Dynamic Type for system faces. Views
  that need Dynamic Type on system text supply their own `@ScaledMetric` and pass the scaled
  value as `size:`. Custom serif (`display()`) and mono (`mono()`) carry Dynamic Type via
  their own `relativeTo`. This is why the 8 source files have `@ScaledMetric` restored. Do
  not change the Core resolver in PR B.
- **② Harness gap = "Fix harnesses + re-record."** The 4 stale snapshot suites set
  `.chatAppearance(...)` but didn't inject `.superTypography`, so they rendered with the
  default typography instead of the scaled one. Fixed by adding
  `.superTypography(.make(.serif, fontScale: <same scale>))` after each `.chatAppearance(...)`
  site. Bridge helper lives in `SettingsSheet.swift`:
  `SuperTypography.make(_ id: ChatSettings.TypographyID, fontScale:)`.

## Environment / tooling gotchas that bit this session

- **CI trio = iPhone 17 / iOS 26.4 / Xcode 26.4.1** (build 17E202). Match exactly.
- **Resolve the booted simulator UDID FRESH every time** —
  `xcrun simctl list devices | grep Booted`. Do NOT reuse a cached UDID; this session wasted
  many calls spawning into a dead/shut-down sim (`code=405 device is not booted`). The sim
  also **shuts down between runs** — re-check it's booted before each xcodebuild, and re-set
  `SNAPSHOT_RECORD` after any reboot (launchctl env does not survive a reboot).
- **Recording**: `xcrun simctl spawn <UDID> launchctl setenv SNAPSHOT_RECORD 1`, then
  `xcodebuild test -scheme Chat -destination "platform=iOS Simulator,id=<UDID>"`. The
  documented `TEST_RUNNER_` prefix does NOT forward — use `launchctl setenv` directly.
  **Unset afterward**: `launchctl setenv SNAPSHOT_RECORD 0`.
- **Correct scheme is `Chat`** (NOT `Chat-Package`; that exits 65 instantly).
- In a record pass, swift-snapshot-testing reports every assertion as a "failure"
  ("issues") because it writes the baseline rather than comparing — a high issue count in
  record mode is expected, not a real failure. `git status` on `__Snapshots__` shows the
  truly-changed bytes (~80 files here).
- Use unique `-resultBundlePath` per run (e.g. `/tmp/chat_verify_1.xcresult`); xcodebuild
  refuses to overwrite an existing bundle.
- Context discipline: redirect xcodebuild output to a file, background it, and read only
  `grep`/`tail` summaries — never dump full logs (that's what blew up the prior session).

## Immediate (new session, first thing)

1. `cd` to the worktree
   `/Users/bwang/Development/Super/.claude/worktrees/fluffy-bouncing-wigderson`.
2. If the working tree is still dirty: commit the `@ScaledMetric` restore + harness fixes +
   re-recorded PNGs, then push `typography-b-shell-chat`. (The abandoning session was asked
   to do exactly this — verify it landed.)

## Verification still required (the actual leftover work)

The 80 PNGs were written in **record mode but never verified by a clean pass.** Until that
passes, PR B is not done.

1. **Clean snapshot pass (record OFF).** Confirm `SNAPSHOT_RECORD=0`/unset on the booted
   sim, run `xcodebuild test -scheme Chat -destination "...id=<fresh-booted-UDID>"`. Expect
   green EXCEPT the 2 known pre-existing flaky `ChatsScreenEventBus` `EventTimeout()` tests
   (NOT PR B's responsibility — note them, don't chase them). If any *snapshot* test fails,
   that surface didn't record cleanly or the resolver isn't byte-identical on the
   system-font path — investigate before re-recording (a real diff, not a re-record-to-pass).
2. **Audit the diff is intentional.** `git show --stat` the snapshot commit. The ~80 changed
   PNGs should be only: serif titles (Instrument Serif Italic via `display()`), JetBrains
   mono surfaces (`mono()`), and Dynamic-Type-XXL / fontScaleMax variants. Eyeball a few
   actual PNGs (titles render Instrument Serif Italic; XXL text reflows correctly). Any
   *unexpected* surface moving = the `.system` path no-op invariant is broken; fix the
   migration, don't re-record.
3. **Both app targets build.** PR B touches `App/Shell/AppShell.swift`, so build BOTH
   `Super` (SuperOS) and `SuperBible` schemes, not just the Chat package.
4. `swift test` from `Packages/Chat/` green (modulo the 2 EventBus flakes).

## Then ship (per `[[feedback_pr_workflow]]`)

review subagent → fix must/should → `gh pr create` → iterate Claude review → auto-merge →
clean worktree. PR description needs a **Test Coverage** section naming the updated snapshot
suites + the `@ScaledMetric`/harness fixes, and noting the 2 pre-existing EventBus flakes as
out-of-scope.

## Out of scope for PR B

- User-facing Settings UI to pick the typeface (the `typography.id` key exists; the picker
  is later).
- Todo (PR C) and Bible (PR D) migrations + the Bible fontScale fix.
- Changing the Core `SuperTypography` resolver (the system-path `relativeTo` drop is handled
  by `@ScaledMetric` in views by design — decision ④).
