import Foundation
import GRDB

/// Register every Todo schema migration in order. Always call this against
/// a fresh `DatabaseMigrator` — appending new migrations is safe;
/// reordering or removing one already applied to a user's database is not.
public func registerTodoMigrations(_ migrator: inout DatabaseMigrator) {

    migrator.registerMigration("v1_createTables") { db in

        try db.create(table: "task") { t in
            t.primaryKey("id", .text)
            t.column("title", .text).notNull()
            t.column("notes", .text).notNull().defaults(to: "")
            t.column("priority", .integer).notNull()
            t.column("state", .text).notNull()
            t.column("dueAt", .datetime)
            t.column("sortOrder", .double).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("deletedAt", .datetime)
        }
        try db.create(
            index: "task_on_state_priority",
            on: "task",
            columns: ["state", "priority"]
        )
        try db.create(
            index: "task_on_dueAt",
            on: "task",
            columns: ["dueAt"]
        )
        try db.create(
            index: "task_on_updatedAt",
            on: "task",
            columns: ["updatedAt"]
        )

        try db.create(table: "label") { t in
            t.primaryKey("id", .text)
            t.column("name", .text).notNull()
            t.column("hue", .double).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("deletedAt", .datetime)
        }
        // Unique on lower(name) enforces the dedupe-on-create contract
        // (a case-insensitive match returns the existing label rather than
        // creating a second row) at the schema level. Filtered by
        // `deletedAt IS NULL` so a soft-deleted label's name can be reused.
        try db.execute(sql: """
            CREATE UNIQUE INDEX label_unique_name_active
            ON label(lower(name)) WHERE deletedAt IS NULL
        """)

        try db.create(table: "taskLabel") { t in
            t.column("taskId", .text).notNull()
                .references("task", onDelete: .cascade)
            t.column("labelId", .text).notNull()
                .references("label", onDelete: .cascade)
            t.column("createdAt", .datetime).notNull()
            t.primaryKey(["taskId", "labelId"])
        }
        try db.create(
            index: "taskLabel_on_labelId",
            on: "taskLabel",
            columns: ["labelId"]
        )
    }
}
