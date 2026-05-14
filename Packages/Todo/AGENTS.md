# Todo — Agent Guidelines

The Todo applet: local task list with priorities, labels, and (eventually) a long-press action menu. UI reference lives at `/tmp/super-design/super/project/Todo.html` (and the loaded `todo/*.jsx` files).

## What lives here

- **Models** (`Models/`): `TaskRecord`, `LabelRecord`, `TaskLabelRecord`, `TaskState`, `TaskPriority`. All persistable records conform to `Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable`.
- **Database** (`Database/`): `TodoDatabase` (wraps `DatabaseQueue` on `todo.sqlite`) and `Migrations`.
- **Repositories** (`Repositories/`): one protocol per table, GRDB-backed `struct` impls.
- **Domain** (`Domain/`): pure projections and filter logic — `TaskWithLabels`, `TodoFilter`, `LabelHuePalette`.
- **ViewModels** (`ViewModels/`): `@Observable @MainActor final class` only.
- **UI** (`UI/`): SwiftUI views — `TodoScreen` (root), `TodoTaskRow`, `TodoStateBox`, `Sheets/Todo*Sheet`, `Sheets/TodoTagPicker`, `Icons/TodoIcon`. View bucket suffixes follow `docs/NAMING_CONVENTIONS.md` Part 4.

## Rules

- **Do not import other applets.** No `import Chat`. Cross-applet communication runs through Core (event bus when it lands; absent in MVP).
- **Persistence is GRDB only.** No SwiftData / Core Data.
- **GRDB naming**: `camelCase` Swift property names = `camelCase` columns. Foreign keys are `<referencedTableSingular>Id`. Primary key is `id` (String UUID). Indexes follow `<tableName>_on_<column>[_<column>]`. See [`docs/NAMING_CONVENTIONS.md` Part 5](../../docs/NAMING_CONVENTIONS.md#part-5--persistence-schema).
- **Schema is sync-ready.** Every persistable row carries `createdAt`, `updatedAt`, `deletedAt?` per `docs/SYNC.md` §6.2. Sync itself is deferred, but the schema must not need a follow-up migration to enable it.
- **Snapshot tests** land in the same PR as the view they cover. Light / dark / sepia × default / Dynamic Type XXL per root AGENTS.md §Testing.
- **Coverage target ≥70%** per root AGENTS.md.

## Tests

`swift test` from `Packages/Todo/` must be green before any PR opens. Snapshot fixtures live in `Tests/TodoTests/UI/__Snapshots__/`.
