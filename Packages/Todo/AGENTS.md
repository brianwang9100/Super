# Todo — Agent Guidelines

The Todo applet: local task list with priorities, labels, and (eventually) a long-press action menu. The UI mirrors the Todo design prototype (`Todo.html` + the `todo/*.jsx` files) — an out-of-tree design asset, not committed to the repo.

## What lives here

- **Models** (`Models/`): `TaskRecord`, `LabelRecord`, `TaskLabelRecord`, `TaskState`, `TaskPriority`. All persistable records conform to `Codable, TableRecord, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable` — `TableRecord` is listed explicitly so the GRDBQuery `@Query` / `ValueObservation` query-interface intent is visible at a glance.
- **Database** (`Database/`): `TodoDatabase` (wraps `DatabaseQueue` on `todo.sqlite`) and `Migrations`.
- **Repositories** (`Repositories/`): one protocol per table, GRDB-backed `struct` impls.
- **Domain** (`Domain/`): pure projections and filter logic — `TaskWithLabels`, `TodoFilter`, `LabelHuePalette`.
- **ViewModels** (`ViewModels/`): `@Observable @MainActor final class` only.
- **UI** (`UI/`): SwiftUI views. The root surface is `TodoScreen`; the applet glyph is `TodoIcon`. Rows, sheets, and nested regions follow the `docs/NAMING_CONVENTIONS.md` Part 4 bucket suffixes (Screen / Sheet / Row / Region / …) — specific view names are coined against that taxonomy as each view is built (M3–M5).

## Todo-specific rules

Root [`../../AGENTS.md`](../../AGENTS.md) carries the shared rules (no cross-applet imports, GRDB-only persistence, GRDB naming, snapshot matrix + Xcode pin, coverage target ≥70%). Todo-specific additions:

- **Schema is sync-ready.** Every persistable row carries `createdAt`, `updatedAt`, `deletedAt?` per `docs/SYNC.md` §6.2. Sync itself is deferred, but the schema must not need a follow-up migration to enable it.

## Tests

`swift test` from `Packages/Todo/` runs the non-UI suites. SwiftUI snapshot suites are gated behind `#if canImport(UIKit)` and run via `xcodebuild test -scheme Todo` against the CI-pinned simulator; their fixtures live in `Tests/TodoTests/UI/Snapshots/__Snapshots__/`.
