# Bible — Agent Guidelines

The Bible mini-applet: a chapter-reading surface with verse selection, highlights, book/chapter and translation pickers.

## What lives here (incremental — builds out per the plan)

- **Applet** (`Applet/`): `BibleApplet` — `MiniApplet` conformance, applet id `"bible"`.
- **UI** (`UI/`): SwiftUI views. **Before naming a new view, read [`docs/NAMING_CONVENTIONS.md` Part 4](../../docs/NAMING_CONVENTIONS.md#part-4--swiftui-view-layer-chat-applet).** Drop the `View` suffix, one struct per file, bucket suffix per the doc (`*Screen`, `*Sheet`, `*Bar`, `*Block`, `*Toast`, `*Bubble`, `*Footer`).

Future milestones add: `Models/`, `Repositories/`, `Database/`, `TextSources/`, `Formatting/`, `ViewModels/`, `Resources/translations/`.

## Rules

- **Do not import other applets.** Cross-applet communication runs through Core. Hand-off to Chat is explicitly deferred (no `SuperEventBus` work in this package).
- **No chat hand-off / bidirectional AI in MVP.** The `+` nav button, the floating "Ask about this chapter…" bubble, and the action sheet's chat rows render per design but no-op with a "Coming soon" toast. Hand-off lands in a follow-up plan once `SuperEventBus` exists.
- **Persistence is GRDB only** when it lands (M2+). No SwiftData / Core Data.
- **GRDB naming**: `camelCase` Swift property names = `camelCase` columns. Foreign keys are `<referencedTableSingular>Id`. Primary key is `id` (String UUID). Indexes follow `<tableName>_on_<column>[_<column>]`. See [`docs/NAMING_CONVENTIONS.md` Part 5](../../docs/NAMING_CONVENTIONS.md#part-5--persistence-schema).
- **Records** are `struct` + `Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable`.
- **View models** are `@Observable @MainActor final class`, named `*ScreenViewModel` / `*SheetViewModel`.
- **Repositories** are protocol-typed at the seam, `GRDB`-prefixed concrete impls.
- **Inject side effects.** Clocks, ID generators, and any future network paths come through Core's protocols. No `Date()` / `UUID()` in testable logic.
- **Snapshot tests** land in the same PR as the view they cover. Per root AGENTS.md §Testing.2: light/dark/sepia × default/Dynamic Type XXL for any view-level change, recorded against CI's Xcode 26.4.1 + iOS 26.4 + iPhone 17 pin.
- **Coverage target ≥70%** per root AGENTS.md.

## Tests

`swift test` from `Packages/Bible/` must be green before any PR opens. Snapshot fixtures live in `Tests/BibleTests/UI/Snapshots/__Snapshots__/`.
