import Core
import Foundation
import GRDB

/// Errors thrown by `ModelConfigurationRepository` operations.
public enum ModelConfigurationRepositoryError: Error, Sendable, Equatable {
    /// `setSelected(id:)` referenced a row that doesn't exist.
    case unknownModel(id: String)
}

/// Persistence boundary for `ModelConfigurationRecord` plus the matching
/// Keychain entry that holds the row's API (Application Programming
/// Interface) key. The repository owns both halves so callers don't have
/// to wire `KeychainClient` separately at every call site.
public protocol ModelConfigurationRepository: Sendable {
    /// Every configured model, ordered by `createdAt` ascending so the UI
    /// shows them in setup order.
    func all() async throws -> [ModelConfigurationRecord]
    /// One row by id, ignoring selection state.
    func fetch(id: String) async throws -> ModelConfigurationRecord?
    /// The currently selected model, if any.
    func selected() async throws -> ModelConfigurationRecord?
    /// Insert or update. Does **not** touch the Keychain — pair with
    /// `storeAPIKey(_:ref:)` when persisting a freshly entered key.
    func save(_ record: ModelConfigurationRecord) async throws
    /// Build and insert a record atomically, but only if the table has
    /// no other rows at the moment of the write. The `make` closure is
    /// called *inside* the write transaction — only when the table is
    /// confirmed empty — so callers using a `DeterministicIDGenerator`
    /// don't burn an id on a no-op call. Returns the inserted record,
    /// or `nil` when the table already had rows.
    ///
    /// Used by first-launch seeding so the empty-check and the insert
    /// run in the same write transaction — a concurrent insert from
    /// another writer between them would otherwise pass the check, then
    /// land a second row that violates the seed's "only on empty"
    /// contract.
    func insertIfEmpty(
        make: @Sendable () -> ModelConfigurationRecord
    ) async throws -> ModelConfigurationRecord?
    /// Delete the row and the matching Keychain entry referenced by its
    /// `apiKeyRef`. The Keychain delete runs first: a Keychain failure
    /// leaves the DB row in place so the caller can retry, instead of
    /// orphaning a secret that no row points at. Safe to call when no
    /// Keychain entry exists.
    func delete(id: String) async throws
    /// Mark `id` as the unique selected row, clearing any prior selection
    /// in the same write transaction.
    /// - Throws: `ModelConfigurationRepositoryError.unknownModel` when no
    ///   row matches `id`.
    func setSelected(id: String) async throws
    /// Persist the plaintext key under `ref` in the Keychain.
    func storeAPIKey(_ key: String, ref: String) async throws
    /// Read the plaintext key back out, or nil if no entry exists.
    func loadAPIKey(ref: String) async throws -> String?
}

/// GRDB-backed `ModelConfigurationRepository`. The selected-exclusive
/// invariant is enforced at the schema level by a partial unique index on
/// `modelConfiguration(isSelected) WHERE isSelected = 1`, so any caller
/// (including `save(_:)`) that tries to land a second selected row hits a
/// SQLite (Structured Query Language) UNIQUE violation. `setSelected(id:)`
/// is the safe path: it demotes the prior selected row in the same write
/// transaction so the index never sees the conflict.
public struct GRDBModelConfigurationRepository: ModelConfigurationRepository {
    private let queue: DatabaseQueue
    private let keychain: any KeychainClient

    public init(database: ChatDatabase, keychain: any KeychainClient) {
        self.queue = database.queue
        self.keychain = keychain
    }

    public func all() async throws -> [ModelConfigurationRecord] {
        try await queue.read { db in
            try Self.knownKindRequest
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    public func fetch(id: String) async throws -> ModelConfigurationRecord? {
        try await queue.read { db in
            try Self.knownKindRequest
                .filter(Column("id") == id)
                .fetchOne(db)
        }
    }

    public func selected() async throws -> ModelConfigurationRecord? {
        try await queue.read { db in
            try Self.knownKindRequest
                .filter(Column("isSelected") == true)
                .fetchOne(db)
        }
    }

    /// Base request that filters to rows whose `kind` matches a case the
    /// running binary actually has. In DEBUG builds that includes
    /// `LLMProviderKind.debug`; in Release it doesn't. The filter exists
    /// so a `kind = "debug"` row seeded by a DEBUG build doesn't crash a
    /// Release launch — GRDB would otherwise call
    /// `LLMProviderKind(rawValue: "debug")` during decode, get `nil`, and
    /// throw `DecodingError.dataCorrupted`, propagating up through
    /// `AppBootstrap`. Rows with an unknown `kind` value are silently
    /// excluded from every read; the unreferenced row stays on disk
    /// unless a future migration cleans it up.
    private static var knownKindRequest: QueryInterfaceRequest<ModelConfigurationRecord> {
        let kinds = LLMProviderKind.allCases.map(\.rawValue)
        return ModelConfigurationRecord.filter(kinds.contains(Column("kind")))
    }

    public func save(_ record: ModelConfigurationRecord) async throws {
        try await queue.write { db in
            try record.save(db)
        }
    }

    public func insertIfEmpty(
        make: @Sendable () -> ModelConfigurationRecord
    ) async throws -> ModelConfigurationRecord? {
        try await queue.write { db in
            // Empty-check must match the read filter — otherwise a row
            // with a `kind` value the binary doesn't recognise (e.g. a
            // leftover DEBUG `kind = "debug"` row) makes the table look
            // non-empty to a Release build, the AFM seed silently
            // no-ops, and `hydrateProviders` ends up with an empty
            // registry. Counting through `knownKindRequest` keeps the
            // empty-check and the subsequent `all()` reads consistent.
            let count = try Self.knownKindRequest.fetchCount(db)
            guard count == 0 else { return nil }
            let record = make()
            // Before inserting a row with `isSelected = 1`, demote any
            // unknown-kind row holding the selection slot. The schema's
            // partial unique index (`WHERE isSelected = 1`) doesn't know
            // about `kind`, so without the demote the insert would
            // UNIQUE-violate when an older binary downgrades into a DB
            // where a newer binary's row sits selected. Demoting is
            // safe — `selected()` filters unknown-kind rows out, so the
            // user can't reach that row anyway.
            if record.isSelected {
                try Self.demoteUnknownKindSelections(db: db)
            }
            try record.insert(db)
            return record
        }
    }

    /// Clear `isSelected` on any row whose `kind` value isn't a known
    /// case in the running binary. The partial unique index on
    /// `isSelected = 1` ignores `kind`, so before inserting a new
    /// selected row we have to free up the slot or risk a UNIQUE
    /// violation. Demoting an unknown-kind row is benign because
    /// `selected()` filters those rows out anyway — the user has no
    /// path to interact with them from this binary.
    private static func demoteUnknownKindSelections(db: Database) throws {
        let kinds = LLMProviderKind.allCases.map(\.rawValue)
        try ModelConfigurationRecord
            .filter(!kinds.contains(Column("kind")))
            .filter(Column("isSelected") == true)
            .updateAll(db, Column("isSelected").set(to: false))
    }

    public func delete(id: String) async throws {
        // Probe via raw SQL — *not* `fetch(id:)` — so the delete path
        // works for rows whose `kind` value the binary doesn't recognise
        // (e.g. a leftover DEBUG `kind = "debug"` row in a Release
        // build). `fetch(id:)` runs through `knownKindRequest` and would
        // return nil for such a row, leaving it permanently orphaned.
        // Inner optional: `apiKeyRef` column value (NULL for AFM-style
        // rows). Outer optional: row existence.
        let probe: (exists: Bool, apiKeyRef: String?) = try await queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT apiKeyRef FROM modelConfiguration WHERE id = ?",
                arguments: [id]
            )
            return row.map { (true, $0["apiKeyRef"] as String?) } ?? (false, nil)
        }
        guard probe.exists else { return }
        // Keychain first: if it throws, the DB row remains and the user
        // can retry instead of orphaning the secret. Skip when the row
        // has no `apiKeyRef` (on-device kinds like `.appleFoundation`
        // never write to the Keychain).
        if let ref = probe.apiKeyRef {
            try await keychain.delete(ref: ref)
        }
        _ = try await queue.write { db in
            try ModelConfigurationRecord.deleteOne(db, key: id)
        }
    }

    public func setSelected(id: String) async throws {
        try await queue.write { db in
            guard try ModelConfigurationRecord.fetchOne(db, key: id) != nil else {
                throw ModelConfigurationRepositoryError.unknownModel(id: id)
            }
            try ModelConfigurationRecord
                .filter(Column("isSelected") == true)
                .updateAll(db, Column("isSelected").set(to: false))
            try ModelConfigurationRecord
                .filter(Column("id") == id)
                .updateAll(db, Column("isSelected").set(to: true))
        }
    }

    public func storeAPIKey(_ key: String, ref: String) async throws {
        try await keychain.setString(key, ref: ref)
    }

    public func loadAPIKey(ref: String) async throws -> String? {
        try await keychain.getString(ref: ref)
    }

    #if DEBUG
    /// DEBUG-only first-launch seed for `DebugLLMProvider`. Inserts a
    /// `kind = .debug` row atomically iff no `.debug` row already exists.
    /// `make` is invoked *inside* the write transaction and receives
    /// `shouldSelect = true` only when the table currently has no
    /// selected row — so a fresh install lands on the debug model by
    /// default, but a developer who has already wired a real provider
    /// keeps that one as active. Returns the inserted record on success,
    /// nil when a debug row was already present.
    ///
    /// Lives on the concrete type (not the protocol) so the in-tree
    /// `Stub`/`NoopModelRepository` test doubles don't have to grow a
    /// DEBUG-only stub.
    public func insertDebugIfMissing(
        make: @Sendable (_ shouldSelect: Bool) -> ModelConfigurationRecord
    ) async throws -> ModelConfigurationRecord? {
        try await queue.write { db in
            let alreadyHasDebug = try ModelConfigurationRecord
                .filter(Column("kind") == LLMProviderKind.debug.rawValue)
                .fetchCount(db) > 0
            guard !alreadyHasDebug else { return nil }
            // `shouldSelect` matches what `selected()` would report —
            // only a row whose `kind` the binary recognises counts as
            // "the active model" from the user's perspective. An
            // unknown-kind row holding the slot is unusable to this
            // binary and shouldn't keep the seed from claiming
            // selection.
            let hasKnownSelected = try Self.knownKindRequest
                .filter(Column("isSelected") == true)
                .fetchCount(db) > 0
            let shouldSelect = !hasKnownSelected
            // Demote any unknown-kind selected row before inserting our
            // own — the schema's partial unique index spans every row
            // regardless of `kind`, so without this an unknown-kind
            // selected row from a newer binary would UNIQUE-violate the
            // debug row's insert.
            if shouldSelect {
                try Self.demoteUnknownKindSelections(db: db)
            }
            let record = make(shouldSelect)
            try record.insert(db)
            return record
        }
    }
    #endif
}
