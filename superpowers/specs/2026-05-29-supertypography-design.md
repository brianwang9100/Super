# SuperTypography — centralized font resolution in Core

**Status:** in progress (PR A landed; B/C/D follow)
**Date:** 2026-05-29

## Problem

Fonts were scattered across ~230 `.font(...)` call sites in four packages with no single
owner. The brand serif (`InstrumentSerif-Italic`) was hard-coded as a string at ~8 sites;
everything else used ad-hoc `.font(.system(...))`. Nothing centrally owned "the display
face," so brand titles in Todo and Bible silently fell back to the **system serif** (New
York) — the bug that kicked this off. There was also no way to swap the type system in one
place, and the per-package Dynamic Type strategy was inconsistent (Todo multiplies
`superFontScale`, Bible ignores it entirely).

## Solution

`SuperTypography` — a `Sendable, Equatable` struct in `Core/Theme/`, the typographic
companion to `SuperTheme`. Where the theme resolves a semantic color token → `Color`,
typography resolves a semantic type role → `Font`. Injected via
`@Environment(\.superTypography)` with a `.superTypography(_:)` modifier, exactly mirroring
the theme plumbing.

### API shape

```swift
public struct SuperTypography: Sendable, Equatable {
    public enum Identifier: String, Sendable, CaseIterable, Codable { case serif, system }
    public enum Role: Sendable { case display, largeTitle, title, title2, title3,
                                       headline, body, callout, subheadline,
                                       footnote, caption, caption2 }

    public let id: Identifier
    public let fontScale: CGFloat      // folded into every accessor
    let displayFace: String?           // nil → system serif design
    let monoFace: String?              // nil → system monospaced design

    public func display(_ size: CGFloat = 36, relativeTo: Font.TextStyle? = .largeTitle) -> Font
    public func font(_ role: Role, weight: Font.Weight? = nil) -> Font
    public func font(size: CGFloat, relativeTo: Font.TextStyle? = nil,
                     weight: Font.Weight? = nil, design: Font.Design = .default) -> Font
    public func mono(_ size: CGFloat, relativeTo: Font.TextStyle? = .caption2,
                     weight: Font.Weight? = nil) -> Font

    public static func make(_ id: Identifier, fontScale: CGFloat = 1) -> SuperTypography
}
```

### Resolution invariants

- **One resolution path.** All accessors funnel through `spec(size:relativeTo:weight:design:)`,
  which returns a pure `FontSpec` descriptor; `FontSpec.font` builds the `SwiftUI.Font`.
  This split exists because **`SwiftUI.Font`'s `==` is provider-sensitive and unreliable** —
  it can't distinguish `.custom(size:)` from `.custom(size:relativeTo:)`, nor the
  `.system(size:weight:)` overloads. Tests assert on `FontSpec`, not `Font`.
- **`.system`-path no-op.** When the active identity has no custom face for the requested
  `design`, the resolver returns `.system(size: base * fontScale, weight:, design:)` and
  **drops `relativeTo`** — byte-identical to the hand-written `.font(.system(size:))` calls
  being migrated. This is what keeps the vast majority of snapshots from moving. (A migrating
  view that wants OS Dynamic Type pairs its own `@ScaledMetric` base with `font(size:)`.)
- **Custom faces opt into Dynamic Type** via `relativeTo:`; pass `relativeTo: nil` for fixed
  marks that must not scale (the splash wordmark).
- **Italic is in the face.** `InstrumentSerif-Italic` is the italic ttf, so `display(_:)`
  needs no `.italic()`. Bible's existing `.italic()` on its chapter title is dropped on
  migration.
- **`fontScale` is folded in** at the struct level, so call sites read one environment value
  and never multiply the scale themselves.

### Swapping the face

Flip `SuperTypographyKey.defaultValue` / the `make` default from `.serif` to `.system`, or
edit the face strings in `make(.serif)` — one place, whole app. A `"typography.id"`
`SettingRecord` (PR B) makes it a persisted, runtime-swappable choice.

## Phasing (4 PRs)

- **PR A (this):** `SuperTypography` + env plumbing + unit tests; migrate Core's own
  `SplashView`. No app-wide behavior change — default `.serif` keeps current faces, and
  `SplashView` snapshots pass without re-record (proves the no-op).
- **PR B:** Inject `.superTypography` in `AppShell` (alongside `.superTheme`/`.superFontScale`),
  add the `"typography.id"` settings key, fold `ChatAppearance` in, migrate all Chat views,
  re-record Chat snapshots.
- **PR C:** Migrate all Todo views (re-pointing the earlier title work), re-record.
- **PR D:** Migrate all Bible views + the **Bible fontScale fix** (Bible currently ignores
  the app font slider; threading `SuperTypography` makes it respect it) + a new Bible snapshot
  font-registration helper, re-record. **Split into D1 (reader surface) + D2 (chrome/sheets):**
  - **PR D1 (done):** the reader surface only — chapter title (now brand serif, `.italic()`
    dropped per *Resolution invariants*), section headings, verse words + raised verse numbers,
    nav bar, and prev/next footer. Added `SnapshotFontRegistration` to Bible (mirrors Chat's),
    wired into the two reader-driver suites, re-recorded `BibleChapterReader` + `BibleScreen`
    baselines, and added a `populated_font_scale_max` (1.2×) variant proving the slider scales
    the whole reader. The other 18 Bible snapshot suites were byte-identical (system-sans sites
    resolve identically at 1.0×), confirming the migration's blast radius is reader-only.
  - **PR D2 (done):** the remaining Bible chrome — book/translation/action/narration sheets,
    annotation + note surfaces, attach toast, and the `BibleScreen` "Chapter unavailable" fallback.
    Mechanical migration: plain `.system(size:)` → `typography.font(size:)` (byte-identical at
    1.0×); `design: .monospaced` sites now resolve the brand **JetBrains Mono** (date stamps,
    verse/note counts, section labels, provenance) and `design: .serif` sites the brand
    **Instrument Serif** (the disclaimer title, the note-list citation, the unavailable fallback);
    `NarrationTransportSheet`'s semantic `.headline`/`.footnote`/`.caption2` styles moved to
    `@ScaledMetric` bases fed through `typography.font(size:)` (byte-identical at default Dynamic
    Type; a sub-pixel shift at DT XXL, the documented metric tradeoff). Added the
    `SnapshotFontRegistration` `init()` to the 10 chrome suites that now render a brand face;
    re-recorded those + the 2 `BibleScreen` `unavailable_*` baselines. The sans-only suites
    (action sheet, attach toast, glyphs, verse trailers) stayed byte-identical, confirming the
    blast radius is exactly the mono/serif surfaces.

This completes the SuperTypography migration: every shipping surface (Core splash, Chat, Todo,
the Bible reader, and the Bible chrome) now resolves its faces through `SuperTypography`.

## Snapshot strategy

Run each package's snapshot suite **without** `SNAPSHOT_RECORD` first. Only deliberately
changed surfaces (brand serif titles, JetBrains-vs-system mono where they differ, Bible at
non-default scale) should fail. An *unexpected* diff means the `.system` path isn't actually
byte-identical — fix the resolver, don't re-record. Re-record only intended surfaces against
CI's pinned trio (Xcode 26.4.1 / iOS 26.4 / iPhone 17). Every test target that renders a
brand face asserts `UIFont(name: "InstrumentSerif-Italic", …) != nil` so a missing
registration fails loudly instead of baking the fallback (Bible needs this helper added in
PR D).

## Out of scope

- A user-facing Settings control to *pick* the typeface (the persistence key is added in PR B;
  the UI is later).
- Replacing the actual faces — this is the plumbing that makes that a one-line change.
