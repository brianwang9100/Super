# PR-6: Brand-asset correctness — icon alpha, SuperOS Vellum refresh, AccentColor (audit P1-3, P2-21, P2-22)

> **For agentic workers:** mechanical asset-generation PR. Verification is generator-run + `sips`/`plutil` inspection + visual PNG review + `xcodegen generate` + build (no app-target unit harness exists — audit P2-19). Steps use checkbox (`- [ ]`) syntax.

**Goal:** Both app targets ship App Store-valid, on-brand assets: icons with **no alpha channel** (ITMS-90717), a **Vellum** SuperOS icon that matches its splash, correct SuperOS launch-background color, and a baked **clay AccentColor** in both targets so system chrome stops leaking blue.

**Architecture:** `Scripts/generate_superbible_brand_assets.swift` is the single source of truth for brand pixels (OKLCH→sRGB ported from `Core/Theme/OKLCH.swift`). It currently emits **SuperBible only**. Generalize it to emit assets for **both** targets, parameterized by a per-target mark (SuperBible = filled Star of Bethlehem; SuperOS = stroked 12-ray `SplashSpark`). Icons render in an **opaque** (`noneSkipLast`) context so the exported PNG carries no alpha; the SuperBible launch image stays **transparent** (`premultipliedLast`).

**Tech Stack:** Swift CLI (CoreGraphics, ImageIO), Xcode asset catalogs, XcodeGen.

---

## Findings addressed

- **P1-3** — Both `AppIcon.png`s have an alpha channel (`sips -g hasAlpha` → `yes`); ASC rejects icon PNGs with alpha (ITMS-90717). Root cause: the generator's `context()` uses `CGImageAlphaInfo.premultipliedLast`. The SuperOS icon was never generator-produced (predates the script) and is hand-baked green.
- **P2-21** — SuperOS `SplashBackground.colorset` is the retired green `#E8EDE4` (sRGB 0.910/0.929/0.894) while `SuperOSContentView` pins `SplashView` to Vellum Light → visible launch color shift. Stale `project.yml` comment references `SuperTheme.light.background = #E8EDE4` (token gone). SuperBible's `project.yml` launch comment is also stale (describes the retired `#3f774d` green field; reality is Vellum cream).
- **P2-22** — Both `AccentColor.colorset`s contain only `{"idiom":"universal"}` (no color) yet `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor` is set → alerts / share sheets / default links render system blue instead of the theme's clay accent.

## Confirmed facts (verified against the tree)

- Vellum Light palette (`Packages/Core/Sources/Core/Theme/SuperTheme.swift:249`): `bg = OKLCH(0.957,0.018,85)`, `bgSunken = OKLCH(0.936,0.022,84)`, `accent = OKLCH(0.520,0.090,52)`. The generator's `vellumBg`/`vellumBgSunken`/`vellumAccent` already match these **exactly**.
- Splash spark stroke color = `accentDark`, computed (`SuperTheme.swift` `assemble`) as `OKLCH(0.36, p.accent.c, h)` for light = **`OKLCH(0.36, 0.090, 52)`**. The SuperOS icon spark will use this so icon and splash read identically.
- `SplashSpark` geometry: 12 rays, endpoints normalized `/24` of the box (`Packages/Core/Sources/Core/Theme/SplashSpark.swift`). Ported verbatim into the generator.
- SuperBible launch image is intentionally a star on **transparent** ground (the Vellum field comes from `SplashBackground` behind it) — must keep its alpha.
- Design decision (user, 2026-06-13): **refresh** the SuperOS icon to a clay spark on Vellum cream — not just flatten the green.

## Files

- **Modify:** `Scripts/generate_superbible_brand_assets.swift` — generalize to both targets; opaque icon context; add `SplashSpark` mark + SuperOS branch; emit `AccentColor.colorset` for both; emit SuperOS `SplashBackground.colorset`.
- **Regenerate (commit the pixels/JSON):**
  - `App-SuperBible/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (alpha dropped)
  - `App-SuperBible/Assets.xcassets/AccentColor.colorset/Contents.json` (clay)
  - `App-SuperOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (new Vellum spark, no alpha)
  - `App-SuperOS/Assets.xcassets/AccentColor.colorset/Contents.json` (clay)
  - `App-SuperOS/Assets.xcassets/SplashBackground.colorset/Contents.json` (Vellum cream)
  - (`App-SuperBible/.../SplashBackground.colorset/Contents.json` — re-emitted; expected byte-identical)
  - (SuperBible `LaunchImage` `launch@2x/3x.png` — re-emitted; expected byte-identical, still transparent)
- **Modify:** `project.yml` — fix the two stale `UILaunchScreen` comments (SuperOS green token; SuperBible `#3f774d` green field) to describe Vellum cream. No build-setting change (accent name + appicon name already wired).
- Run `xcodegen generate` and commit any `project.pbxproj`/`Info.plist` delta for determinism (expected none from comment-only edits).

## Approach

### Task 1: Generalize the generator — opaque icon context + per-target marks

- [ ] **Step 1: Add an `opaque` flag to `context(_:)`** → `noneSkipLast` when opaque (RGBX, no alpha channel in the exported PNG). Icons fill the full square so dropping alpha is lossless; passes ITMS-90717.
- [ ] **Step 2: Port `SplashSpark`** (12 rays normalized `/24`) + a `drawSpark(in:px:coverage:strokeFraction:stroke:)` that strokes round-capped lines, `lineWidth = box * strokeFraction`.
- [ ] **Step 3: Add `vellumAccentDark = (0.360, 0.090, 52.0)`** + a single `writeColorset(_:to:)` emitter reused for both AccentColor and SplashBackground.

### Task 2: Emit both targets

- [ ] **Step 4: Parameterize paths per target.**
  - **SuperBible** (`App-SuperBible/Assets.xcassets`): AppIcon `context(1024, opaque: true)` fill `bgSunken` + `drawStar(coverage: 0.66, fill: accent)`; LaunchImage `@2x/@3x` **transparent** `drawStar(coverage: 1.0, fill: accent)` (unchanged); SplashBackground ← `bg`; AccentColor ← `accent`.
  - **SuperOS** (`App-SuperOS/Assets.xcassets`): AppIcon `context(1024, opaque: true)` fill `bgSunken` + `drawSpark(coverage: <tuned>, strokeFraction: <tuned>, stroke: accentDark)`; SplashBackground ← `bg`; AccentColor ← `accent`. **No** LaunchImage (SuperOS launch is color-only).
- [ ] **Step 5: Guard both asset dirs exist** (clear error if run outside repo root).

### Task 3: Run, tune, verify pixels

- [ ] **Step 6:** `swift Scripts/generate_superbible_brand_assets.swift` from the worktree root.
- [ ] **Step 7:** `sips -g hasAlpha` on **both** `AppIcon.png` → `no` (P1-3 regression gate).
- [ ] **Step 8:** Visually review both icons (Read the PNGs). Tune SuperOS `coverage`/`strokeFraction` so the spark has presence comparable to the SuperBible star (start `coverage: 0.62`, `strokeFraction: 0.085`; re-render until right). Confirm clay-on-cream, centered, no clipping.
- [ ] **Step 9:** Inspect all four colorsets → SuperOS SplashBackground now cream (== SuperBible's), both AccentColors clay, alpha 1.0.

### Task 4: Comments + project regen + build

- [ ] **Step 10:** Fix the two stale `project.yml` `UILaunchScreen` comments (keep the valid clipping-blends-into-field mechanism note; correct only the color).
- [ ] **Step 11:** `xcodegen generate`; commit any `project.pbxproj`/`Info.plist` delta (expected none). Confirm `xcodegen` version == CI pin (2.45.4).
- [ ] **Step 12:** Build **both** schemes to the CI-pinned sim (iPhone 17, iOS 26.4 `23E254a`); asset catalog compiles clean (no `actool` alpha/empty-accent warnings). Read `$BUILT_PRODUCTS_DIR` from build settings.
- [ ] **Step 13:** `swift test -Xswiftc -warnings-as-errors` in any touched package — **none** are (assets only); `SplashViewSnapshotTests` render the SwiftUI view, not these PNGs, so they're unaffected.

## Verification summary (for the PR Test Coverage section)

1. `sips -g hasAlpha` → `no` on both icons (P1-3 gate; was `yes`).
2. Visual review of both regenerated icons (clay star / clay spark on Vellum cream).
3. Colorset JSON: SuperOS SplashBackground cream (matches SuperBible), both AccentColors clay, alpha 1.0 (P2-21, P2-22).
4. Both schemes build to the CI-pinned sim; asset catalog compiles clean.
5. `project.yml` comments truthful; `xcodegen generate` deterministic (no stray pbxproj churn).

## Out of scope (later roadmap)

- P3-46 (dark/tinted icon variants + Icon Composer asset) — separate design pass.
- PR-7..9 typography migration → SwiftLint expansion; PR-10 Bible BGTask expiration.

## Workflow

Built in the `pr5-privacy-manifests` worktree dir on branch `worktree-pr6-brand-assets` off `origin/main` (the per-PR session is continued; the directory name is cosmetic). Review subagent (default model — `fable` unavailable) → fix MUST/SHOULD → PR with Test Coverage section → claude-review loop → APPROVE → squash auto-merge → STOP and pause.
