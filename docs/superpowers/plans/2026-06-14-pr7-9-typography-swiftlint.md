# PR-7/8/9 (combined): Typography migration + SwiftLint expansion (audit P1-1, P1-2, P3-50)

> Combines the roadmap's Phase-C series into one PR per user request ("do pr7-9 all at once"). The series is migrate-before-enforce, so the lint-gate flip is a no-op once the migrations land — combining is safe.

**Goal:** Route every remaining raw `.font(.system…)` through `SuperTypography`, then expand the SwiftLint gate to cover Bible, Todo, and both app targets so the typography contract (and `force_try`/`force_cast`) is enforced everywhere.

**Tech Stack:** Swift 6 / SwiftPM, swift-snapshot-testing, SwiftLint.

---

## Findings

- **P1-1** — SwiftLint's `included:` only covered App/Core/Chat; Bible (126 files), Todo (32), App-SuperOS, App-SuperBible got zero linting, so the `super_typography_only` error rule couldn't see violations there.
- **P1-2** — ~50 raw `.font(.system(...))` calls in those unlinted surfaces bypassed `SuperTypography` (Todo hand-folded `* fontScale`, Bible used it for SF-Symbol sizing).
- **P3-50** — `force_try`/`force_cast` were downgraded to `warning`; restore to `error`.
- Drive-bys: **P3-38** (`TodoTagChip` → file-private, doc fix), **P3-40** (document `TodoToast`'s intentional theme-independent colors), **P3-43** (`FailureScreen` → typography + theme tokens), **P3-15** Todo half (5 stale "three themes" suite comments).

## Migration rule (uniform)

`.font(.system(size: EXPR, weight: W, design: D))` → `.font(typography.font(size: EXPR′, weight: W, design: D))` where `EXPR′` drops any `* fontScale` factor (the accessor folds the app slider itself — leaving it double-scales). `@ScaledMetric` bases pass straight through as `size` (they carry Dynamic Type; the accessor carries the slider — the canonical dual-axis pattern). Add `@Environment(\.superTypography) private var typography` where absent; drop any now-unused `@Environment(\.superFontScale)`.

**No-op at fontScale 1.0× for system-design / SF-Symbol calls** (`.system(size: N)` ≡ `typography.font(size: N)`). The **intended visual changes**: `design: .monospaced` now resolves to the brand mono face (JetBrains Mono, not SF Mono); previously-fixed sizes now scale with the slider; `AppletPlaceholderScreen` title now renders EB Garamond via `display(_:)`.

## Files

- **Todo** (10): `TodoStateBox`, `TodoToast`, `TodoEmptyState`, `TodoFilterPill`, `TodoSectionHeader`, `TodoTaskRow` (+ `TodoTagChip` private), `TodoScreen`, `Sheets/{TodoFilterSheet, TodoTagPicker, TodoTaskEditorSheet}`.
- **Bible** (6): `BulkAnnotationAtoms`, `BulkAnnotationButtons`, `BulkAnnotationProgressScreen`, `BulkBookSelectionRows`, `BulkJobCard`, `GenerateAnnotationsSheet` — all SF-Symbol sizing.
- **App** (2): `App-SuperOS/Placeholders/AppletPlaceholderScreen` (→ `display`/`font(.callout)`), `App/Shell/FailureScreen` (+ `import Core`, theme tokens).
- **Lint sites** (3): `DebugBibleTarget` ×2 + `SidebarDrawerSnapshotTests` ×1 get `// swiftlint:disable:next force_try` (ChatSession's 2 already had it).
- **Config/docs**: `.swiftlint.yml` (added Bible/Todo Sources+Tests, App-SuperOS, App-SuperBible to `included`; `force_try`/`force_cast` → `error`), root `AGENTS.md` + `Packages/Core/AGENTS.md` coverage claims.
- **Snapshots**: 23 Todo baselines re-recorded (the mono-face + slider-scaling suites: TodoSectionHeader, TodoTaskRow, TodoFilterSheet, TodoTaskEditorSheet, TodoScreen). Bible byte-identical (SF-Symbol no-op).

## Verification

- `swift build -Xswiftc -warnings-as-errors` clean: Todo, Bible, Chat.
- `xcodebuild build` clean: Super + SuperBible (FailureScreen / placeholder compile in app context).
- `swiftlint lint` from repo root → **EXIT 0**, zero error-severity violations (typography + force rules clean; 5 documented `try!` disabled). Opt-in style warnings in the newly-linted dirs remain (non-blocking; CI runs without `--strict`).
- Snapshots on CI-pinned sim (iPhone 17 / iOS 26.4.1 `23E254a` / Xcode 26.4.1): Todo re-recorded then re-verified **TEST SUCCEEDED**; visually confirmed JetBrains Mono renders. All 25 Bible suites **TEST SUCCEEDED** unchanged. The 4 non-mono Todo suites unchanged.

## Out of scope

- Opt-in style-warning cleanup in Bible/Todo (incremental follow-up; warnings don't fail CI).
- P3-15 Core half (SheetNavBar/SplashView comments) — belongs to the docs-reconciliation PR (roadmap E7).

## Workflow

Built in the `pr5-privacy-manifests` worktree dir on branch `worktree-pr7-9-typography-swiftlint` off `origin/main`. Review subagent → fix MUST/SHOULD → PR with Test Coverage → claude-review APPROVE → squash auto-merge → STOP.
