import Core
import Foundation
import GRDB

/// Errors thrown by `ModelConfigurationRepository` operations.
public enum ModelConfigurationRepositoryError: Error, Sendable, Equatable {
    /// `setSelected(id:)` referenced a row that doesn't exist.
    case unknownModel(id: String)
    /// `setSelected(id:)` referenced a row whose `kind` the running binary
    /// can't build a provider for (a native-search kind with no shipped
    /// adapter). Selecting it would demote every other row and then make
    /// `selected()` return nil — leaving no active model. The repository
    /// refuses instead of wedging the app.
    case unselectableKind(id: String, kind: String)
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
    /// Predicate deciding which kinds this binary can build a provider for —
    /// the repository's notion of "buildable" (it can't consult the runtime
    /// HTTP-client/AFM availability the factory does; for persistence purposes
    /// "buildable" means the binary has an adapter for the kind). Defaults to
    /// `LLMProviderKind.hasProviderAdapter`.
    ///
    /// Injectable so the known-but-unbuildable-kind guards stay testable: as of
    /// web-search PR3c every shipping kind is buildable, so that scenario is
    /// otherwise unreachable until a future native kind is added ahead of its
    /// adapter. Tests inject a predicate that marks one real kind unbuildable to
    /// drive the `selected()`/seed/`setSelected` filters.
    private let isKindBuildable: @Sendable (LLMProviderKind) -> Bool
    /// Raw values of the buildable subset, derived once from `isKindBuildable`
    /// (fixed for the repository's lifetime — `selected()` runs on every launch
    /// and selection change, so it's computed here rather than per request).
    private let buildableKindRawValues: [String]

    public init(
        database: ChatDatabase,
        keychain: any KeychainClient,
        isKindBuildable: @escaping @Sendable (LLMProviderKind) -> Bool = { $0.hasProviderAdapter }
    ) {
        self.queue = database.queue
        self.keychain = keychain
        self.isKindBuildable = isKindBuildable
        self.buildableKindRawValues = LLMProviderKind.allCases.filter(isKindBuildable).map(\.rawValue)
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
            try buildableKindRequest
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
    /// the host bootstrap. Rows with an unknown `kind` value are silently
    /// excluded from every read; the unreferenced row stays on disk
    /// unless a future migration cleans it up.
    /// Raw values of every known kind (the buildable subset is the instance
    /// `buildableKindRawValues`, derived from the injected predicate). Fixed at
    /// compile time, so computed once.
    private static let knownKindRawValues: [String] =
        LLMProviderKind.allCases.map(\.rawValue)

    private static var knownKindRequest: QueryInterfaceRequest<ModelConfigurationRecord> {
        ModelConfigurationRecord.filter(knownKindRawValues.contains(Column("kind")))
    }

    /// Like `knownKindRequest`, but further restricted to kinds the running
    /// binary can actually build a provider for (`hasProviderAdapter`). The
    /// native-search kinds (`.anthropicNative` etc.) decode fine but have no
    /// adapter yet, so a row carrying one must not be returned as the
    /// `selected()` model: hydration would skip it, `setActive` would throw
    /// `unknownProvider`, the throw would be swallowed, and the registry
    /// would be left with no active provider. Filtering them out of
    /// `selected()` instead lets the first-registered fallback fire cleanly.
    /// `all()`/`fetch(id:)` keep using `knownKindRequest` so such a row is
    /// still visible/editable in the Models list — it just can't be active.
    private var buildableKindRequest: QueryInterfaceRequest<ModelConfigurationRecord> {
        ModelConfigurationRecord.filter(buildableKindRawValues.contains(Column("kind")))
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
            // Empty-check must match what `selected()` can actually surface
            // as the active model — otherwise a row the binary can't build a
            // provider for makes the table look non-empty, the AFM seed
            // silently no-ops, and `hydrateProviders` ends up with an empty
            // registry. Counting through `buildableKindRequest` (the same
            // filter `selected()` uses) excludes both unrecognised `kind`
            // values (e.g. a leftover DEBUG `kind = "debug"` row in a Release
            // build) and known-but-unbuildable native-search kinds — so a DB
            // carrying only a native-kind row still seeds AFM and the user
            // keeps a recoverable model.
            let count = try buildableKindRequest.fetchCount(db)
            guard count == 0 else { return nil }
            let record = make()
            // Before inserting a row with `isSelected = 1`, demote any
            // unselectable row holding the selection slot (unknown-kind or
            // native-kind). The schema's partial unique index
            // (`WHERE isSelected = 1`) doesn't know about `kind`, so without
            // the demote the insert would UNIQUE-violate when a newer binary
            // left a selected row this build can't surface. Demoting is
            // safe — `selected()` filters those rows out, so the user can't
            // reach them as the active model anyway.
            if record.isSelected {
                try demoteUnselectableSelections(db: db)
            }
            try record.insert(db)
            return record
        }
    }

    /// Clear `isSelected` on any selected row the running binary can't
    /// surface as the active model — i.e. any row whose `kind` is *not*
    /// buildable (`buildableKindRawValues`). That covers two cases: a
    /// truly-unknown `kind` from a newer binary, and a known-but-not-yet-
    /// buildable native-search kind (`.anthropicNative` etc.). The partial
    /// unique index on `isSelected = 1` ignores `kind`, so before inserting
    /// a new selected row we have to free up the slot or risk a UNIQUE
    /// violation. Demoting is benign because `selected()` filters these
    /// rows out anyway (it also runs through `buildableKindRequest`), so the
    /// user has no path to reach them as the active model from this binary.
    private func demoteUnselectableSelections(db: Database) throws {
        try ModelConfigurationRecord
            .filter(!buildableKindRawValues.contains(Column("kind")))
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
            guard let record = try ModelConfigurationRecord.fetchOne(db, key: id) else {
                throw ModelConfigurationRepositoryError.unknownModel(id: id)
            }
            // Refuse to select a row this binary can't surface as the active
            // model. `selected()` filters non-buildable kinds (the native-
            // search kinds) through `buildableKindRequest`, so selecting one
            // here would demote every other row and then yield nil from
            // `selected()` — no active model, no error. Guard before the
            // demote so the prior selection is left intact. Consistent with
            // the seed paths' buildable-kind checks.
            guard isKindBuildable(record.kind) else {
                throw ModelConfigurationRepositoryError.unselectableKind(
                    id: id, kind: record.kind.rawValue
                )
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
            // `shouldSelect` matches what `selected()` would report — only a
            // row this binary can build a provider for counts as "the active
            // model" from the user's perspective. A row the binary can't
            // surface (an unknown `kind`, or a known-but-unbuildable
            // native-search kind) is unusable here and shouldn't keep the
            // seed from claiming selection. Filter through `buildableKindRequest`
            // so this stays consistent with `selected()`.
            let hasBuildableSelected = try buildableKindRequest
                .filter(Column("isSelected") == true)
                .fetchCount(db) > 0
            let shouldSelect = !hasBuildableSelected
            // Demote any unselectable selected row before inserting our own —
            // the schema's partial unique index spans every row regardless of
            // `kind`, so without this an unknown- or native-kind selected row
            // from a newer binary would UNIQUE-violate the debug row's insert.
            if shouldSelect {
                try demoteUnselectableSelections(db: db)
            }
            let record = make(shouldSelect)
            try record.insert(db)
            return record
        }
    }
    #endif
}
