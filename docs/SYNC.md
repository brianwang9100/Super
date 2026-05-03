# Super: Sync Mechanism

> Platform-agnostic, offline-first synchronization engine for cross-device data consistency across all Super applets.

**Prerequisite reading:** [MOBILE_ARCHITECTURE.md](./MOBILE_ARCHITECTURE.md) for data architecture and the custom sync decision (ADR-010), [CLIENT_SERVER.md](./CLIENT_SERVER.md) for the sync transport protocol. [PRODUCT_VISION.md](./PRODUCT_VISION.md) Section 2.4 (Local-First, Cloud-Enhanced) for the guiding philosophy.

> **Status (2026-05-03):** Not built yet. The MVP is single-device — each install holds its own GRDB store with no replication. This document describes the target sync engine; no `SyncEngine` type exists in the codebase. Tracked in [`TODO.md`](../TODO.md) § Sync engine.

---

## 1. Goals & Constraints

The sync engine is one of the most architecturally significant components in Super. It must satisfy every constraint in the table below simultaneously — when two design options conflict, the higher-priority constraint wins.

| Priority | Constraint | Implication |
|----------|-----------|-------------|
| P0 | **Offline-first** | The app works without a network. Local writes are never blocked by sync. Changes queue and sync when connectivity returns. |
| P0 | **Applet-independent** | Each applet opts into sync by conforming to a protocol. No applet knows about another applet's sync behavior. The sync engine has zero applet-specific logic. |
| P0 | **Data integrity** | No user data is silently lost. Conflicts are detected and resolved deterministically. |
| P1 | **Platform-agnostic** | The sync protocol (HTTP API, payload format, conflict resolution rules) works with any client platform — Swift/GRDB today, Kotlin/Room or TypeScript/IndexedDB in the future. |
| P1 | **Reusable** | The sync engine is extractable as a standalone Swift Package that other apps can adopt with zero Super dependencies. |
| P2 | **Efficient** | Sync transfers only deltas (changed fields), not full records. Bandwidth and battery are precious on mobile. |
| P2 | **Solo-dev friendly** | Minimize operational complexity. No CRDTs, no custom merge servers, no distributed consensus. Simple primitives that are easy to reason about and debug. |

### Non-Goals (v1)

- **Real-time collaboration** — Super is a personal productivity app. Multi-user real-time editing is out of scope.
- **Peer-to-peer sync** — All sync flows through the backend. No device-to-device sync.
- **Streaming sync** — WebSocket-based live sync is a future enhancement. v1 uses request/response HTTP.

---

## 2. High-Level Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      Client Device                       │
│                                                          │
│  ┌──────────┐  ┌──────────┐  ┌────────┐  ┌──────────┐  │
│  │ Chat │  │  Calendar  │  │ ToDo  │  │ Home  │  │
│  │  .sqlite │  │  .sqlite │  │ .sqlite│  │  .sqlite │  │
│  └────┬─────┘  └────┬─────┘  └───┬────┘  └────┬─────┘  │
│       │              │            │             │        │
│       ▼              ▼            ▼             ▼        │
│  ┌──────────────────────────────────────────────────┐   │
│  │              SyncEngine (Core package)            │   │
│  │                                                    │   │
│  │  ┌────────────┐ ┌────────────┐ ┌───────────────┐  │   │
│  │  │ChangeTracker│ │SyncScheduler│ │ConflictResolver│ │   │
│  │  └────────────┘ └────────────┘ └───────────────┘  │   │
│  │  ┌────────────┐ ┌────────────┐                    │   │
│  │  │ SyncClient │ │ SyncCursor │                    │   │
│  │  │  (HTTP)    │ │  Store     │                    │   │
│  │  └────────────┘ └────────────┘                    │   │
│  └──────────────────────┬───────────────────────────┘   │
│                          │                               │
└──────────────────────────┼───────────────────────────────┘
                           │ HTTPS (JSON payloads)
                           ▼
┌──────────────────────────────────────────────────────────┐
│                    Backend (super-server)              │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │                  Sync Module                      │   │
│  │                                                    │   │
│  │  ┌────────────┐ ┌────────────┐ ┌───────────────┐  │   │
│  │  │ Push Handler│ │Pull Handler│ │ Merge Engine  │  │   │
│  │  └────────────┘ └────────────┘ └───────────────┘  │   │
│  │  ┌────────────┐ ┌────────────┐                    │   │
│  │  │  Version   │ │  Conflict  │                    │   │
│  │  │  Manager   │ │  Detector  │                    │   │
│  │  └────────────┘ └────────────┘                    │   │
│  └──────────────────────┬───────────────────────────┘   │
│                          │                               │
│  ┌──────────────────────▼───────────────────────────┐   │
│  │              PostgreSQL                           │   │
│  │  ┌──────────────┐ ┌──────────────────────────┐   │   │
│  │  │ sync_changes │ │ applet data tables        │   │   │
│  │  │ (change log) │ │ (canonical merged state)  │   │   │
│  │  └──────────────┘ └──────────────────────────┘   │   │
│  └──────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
```

### 2.1 Component Responsibilities

| Component | Location | Role |
|-----------|----------|------|
| **ChangeTracker** | Client (Core) | Captures local writes into a `syncLog` table via GRDB write hooks |
| **SyncScheduler** | Client (Core) | Decides when to sync (foreground, connectivity change, periodic, manual) |
| **SyncClient** | Client (Core) | HTTP transport — pushes change sets, pulls remote changes |
| **ConflictResolver** | Client (Core) | Applies remote changes to local DB, resolving conflicts per policy |
| **SyncCursor Store** | Client (Core) | Persists the last-synced server version per applet |
| **Push Handler** | Server (sync module) | Receives client change sets, validates, merges into canonical state |
| **Pull Handler** | Server (sync module) | Returns changes since a given server version |
| **Merge Engine** | Server (sync module) | Applies incoming changes to Postgres, detects conflicts |
| **Version Manager** | Server (sync module) | Assigns monotonically increasing server versions to every change |

---

## 3. Change Tracking

### 3.1 The `syncLog` Table

Every applet database that opts into sync contains a `syncLog` table. This table is managed entirely by the sync engine — applets never read or write to it directly.

```swift
// Core/Sync/SyncLogEntry.swift
struct SyncLogEntry: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "syncLog"

    var id: String                  // UUID v7 (time-ordered)
    var tableName: String           // e.g., "task", "project"
    var recordId: String            // primary key of the changed record
    var operation: SyncOperation    // .insert, .update, .delete
    var changedFields: String?      // JSON object of only the fields that changed (null for deletes)
    var fullRecord: String?         // JSON of the complete record (for inserts, and periodic snapshots)
    var timestamp: Date             // client-side wall clock (for reference only, not used for ordering)
    var synced: Bool                // false until server confirms receipt
    var serverVersion: Int64?       // assigned by server on confirmation
}

enum SyncOperation: String, Codable {
    case insert
    case update
    case delete
}
```

### 3.2 How Changes Are Captured

Changes are captured via GRDB's `TransactionObserver` protocol, which provides database-level observation without requiring applets to modify their write code.

```swift
// Core/Sync/SyncChangeTracker.swift
final class SyncChangeTracker: TransactionObserver {
    private let syncedTables: Set<String>
    private var pendingChanges: [SyncLogEntry] = []

    init(syncedTables: Set<String>) {
        self.syncedTables = syncedTables
    }

    // Called for every row-level change inside a transaction
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        switch eventKind {
        case .insert(let tableName), .update(let tableName), .delete(let tableName):
            return syncedTables.contains(tableName)
        }
    }

    func databaseDidChange(with event: DatabaseEvent) {
        let entry = SyncLogEntry(
            id: UUID().uuidString,
            tableName: event.tableName,
            recordId: "\(event.rowID)",
            operation: SyncOperation(from: event.kind),
            changedFields: nil,  // populated in databaseDidCommit
            fullRecord: nil,
            timestamp: Date(),
            synced: false,
            serverVersion: nil
        )
        pendingChanges.append(entry)
    }

    func databaseDidCommit(_ db: Database) {
        // Enrich pending changes with field-level diffs
        for var entry in pendingChanges {
            if entry.operation == .insert || entry.operation == .update {
                // Read the current record to capture the full/changed state
                entry.fullRecord = fetchRecordJSON(db: db, table: entry.tableName, rowId: entry.recordId)
            }
            try? entry.insert(db)
        }
        pendingChanges.removeAll()
    }

    func databaseDidRollback(_ db: Database) {
        pendingChanges.removeAll()
    }
}
```

### 3.3 Field-Level Change Detection

For updates, the sync engine captures only the fields that changed rather than the full record. This is achieved by comparing the previous and current record state.

**Strategy:** Each synced table must include an `updatedFields` transient mechanism. The recommended approach is a shadow column or a before-update snapshot:

```swift
// Applets provide a diff function as part of their SyncableRecord conformance
protocol SyncableRecord: FetchableRecord, PersistableRecord, Codable {
    /// The table name used in syncLog
    static var syncTableName: String { get }

    /// Primary key column name (usually "id")
    static var syncPrimaryKey: String { get }

    /// Computes the JSON diff between two versions of the record
    func changedFields(from previous: Self) -> [String: AnyCodable]
}
```

### 3.4 Sync Log Compaction

The `syncLog` table is compacted after successful sync to prevent unbounded growth:

| Trigger | Action |
|---------|--------|
| After successful push | Delete entries where `synced == true` and `serverVersion` is older than the confirmed cursor |
| On app launch | Compact entries older than 30 days that are marked `synced` |
| Multiple changes to same record | Before push, coalesce: multiple updates to the same `(tableName, recordId)` merge into a single change set. Insert followed by delete cancels out. |

---

## 4. Sync Protocol

### 4.1 Versioning: Server-Assigned Monotonic Versions

Every change that the server accepts is assigned a monotonically increasing `serverVersion` (a `BIGINT` sequence). This is the single source of ordering truth.

**Why not vector clocks?**

| Approach | Pros | Cons |
|----------|------|------|
| **Server version (chosen)** | Simple, deterministic, easy to reason about, one comparison for "what's new" | Requires server round-trip to establish order |
| Vector clocks | No server needed for ordering | Complex, hard to debug, overkill for a client-server topology |
| Hybrid Logical Clocks | Combine wall clock and logical ordering | Adds complexity without clear benefit for our single-server architecture |

The server version approach fits our constraints: all sync flows through one server, so the server can be the single arbiter of ordering.

### 4.2 Sync Cursor

Each client persists a per-applet sync cursor — the `serverVersion` of the last change it has seen.

```swift
// Core/Sync/SyncCursorStore.swift
struct SyncCursor: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "syncCursor"

    var appletId: String        // e.g., "todo"
    var lastServerVersion: Int64 // the highest serverVersion this client has seen
    var lastSyncDate: Date       // when the last sync completed (for diagnostics)
}
```

### 4.3 Push: Client Sends Changes to Server

```
POST /api/v1/sync/{appletId}/push
Authorization: Bearer <jwt>
Content-Type: application/json
```

**Request body:**

```json
{
  "clientId": "device-uuid",
  "baseVersion": 42,
  "changes": [
    {
      "id": "change-uuid-1",
      "tableName": "task",
      "recordId": "record-uuid",
      "operation": "insert",
      "data": {
        "id": "record-uuid",
        "title": "Buy groceries",
        "priority": "high",
        "status": "todo",
        "createdAt": "2026-03-14T10:30:00Z",
        "updatedAt": "2026-03-14T10:30:00Z"
      },
      "timestamp": "2026-03-14T10:30:00Z"
    },
    {
      "id": "change-uuid-2",
      "tableName": "task",
      "recordId": "existing-uuid",
      "operation": "update",
      "data": {
        "priority": "urgent",
        "updatedAt": "2026-03-14T10:31:00Z"
      },
      "timestamp": "2026-03-14T10:31:00Z"
    }
  ]
}
```

**Response (success):**

```json
{
  "accepted": [
    { "changeId": "change-uuid-1", "serverVersion": 43 },
    { "changeId": "change-uuid-2", "serverVersion": 44 }
  ],
  "rejected": [],
  "newVersion": 44
}
```

**Response (conflict):**

```json
{
  "accepted": [
    { "changeId": "change-uuid-1", "serverVersion": 43 }
  ],
  "rejected": [
    {
      "changeId": "change-uuid-2",
      "reason": "conflict",
      "serverRecord": {
        "id": "existing-uuid",
        "priority": "low",
        "status": "in_progress",
        "updatedAt": "2026-03-14T10:30:45Z"
      },
      "serverVersion": 41
    }
  ],
  "newVersion": 43
}
```

### 4.4 Pull: Client Requests Remote Changes

```
GET /api/v1/sync/{appletId}/pull?since=42&limit=500
Authorization: Bearer <jwt>
```

**Response:**

```json
{
  "changes": [
    {
      "serverVersion": 43,
      "tableName": "task",
      "recordId": "record-uuid",
      "operation": "insert",
      "data": {
        "id": "record-uuid",
        "title": "Buy groceries",
        "priority": "high",
        "status": "todo",
        "createdAt": "2026-03-14T10:30:00Z",
        "updatedAt": "2026-03-14T10:30:00Z"
      },
      "clientId": "other-device-uuid",
      "timestamp": "2026-03-14T10:30:00Z"
    }
  ],
  "latestVersion": 44,
  "hasMore": false
}
```

When `hasMore` is `true`, the client must paginate by calling pull again with `since` set to the last `serverVersion` received.

### 4.5 Full Sync (Initial Download)

When a client has no sync cursor (fresh install or applet just enabled sync), it performs a full sync:

```
GET /api/v1/sync/{appletId}/pull?since=0&limit=500
```

This returns all changes from the beginning, paginated. The client applies them sequentially to build the local database from scratch.

**Optimization for large datasets:** For applets with significant history, the server can provide a snapshot endpoint:

```
GET /api/v1/sync/{appletId}/snapshot
```

This returns the current state of all records (not the change history), which is faster to apply than replaying thousands of individual changes.

### 4.6 Sync Flow Sequence

```
Client                              Server
  │                                    │
  │──── Pull (since=lastVersion) ────▶│
  │◀─── Remote changes ──────────────│
  │                                    │
  │  [Apply remote changes locally]    │
  │  [Resolve any conflicts]           │
  │                                    │
  │──── Push (local changes) ────────▶│
  │◀─── Accept/reject response ──────│
  │                                    │
  │  [Mark synced entries]             │
  │  [Update sync cursor]             │
  │                                    │
```

**Pull-before-push ordering is critical.** By pulling first, the client has the latest server state before pushing. This reduces conflicts: the client can rebase its local changes against the freshly pulled state before sending them.

### 4.7 Server-Side Implementation

```typescript
// super-server/src/modules/sync/service.ts
import { db } from '../../shared/database';
import { syncChanges, appletData } from './schema';
import { eq, gt, and, sql } from 'drizzle-orm';

interface PushRequest {
  clientId: string;
  baseVersion: number;
  changes: ChangeEntry[];
}

interface ChangeEntry {
  id: string;
  tableName: string;
  recordId: string;
  operation: 'insert' | 'update' | 'delete';
  data: Record<string, unknown> | null;
  timestamp: string;
}

async function handlePush(
  userId: string,
  appletId: string,
  request: PushRequest
): Promise<PushResponse> {
  const accepted: AcceptedChange[] = [];
  const rejected: RejectedChange[] = [];

  await db.transaction(async (tx) => {
    for (const change of request.changes) {
      // Check for conflicts: has this record been modified since client's baseVersion?
      const existing = await tx.query.syncChanges.findFirst({
        where: and(
          eq(syncChanges.userId, userId),
          eq(syncChanges.appletId, appletId),
          eq(syncChanges.tableName, change.tableName),
          eq(syncChanges.recordId, change.recordId),
          gt(syncChanges.serverVersion, request.baseVersion)
        ),
        orderBy: (t, { desc }) => [desc(t.serverVersion)],
      });

      if (existing && change.operation === 'update') {
        // Conflict detected — attempt per-field merge or reject
        const resolution = resolveConflict(existing, change);
        if (resolution.type === 'merged') {
          const version = await nextVersion(tx, userId, appletId);
          await insertChange(tx, userId, appletId, change, version, resolution.mergedData);
          accepted.push({ changeId: change.id, serverVersion: version });
        } else {
          rejected.push({
            changeId: change.id,
            reason: 'conflict',
            serverRecord: existing.data,
            serverVersion: existing.serverVersion,
          });
        }
      } else {
        // No conflict — accept the change
        const version = await nextVersion(tx, userId, appletId);
        await insertChange(tx, userId, appletId, change, version, change.data);
        accepted.push({ changeId: change.id, serverVersion: version });
      }
    }
  });

  return {
    accepted,
    rejected,
    newVersion: accepted.length > 0
      ? accepted[accepted.length - 1].serverVersion
      : request.baseVersion,
  };
}

async function handlePull(
  userId: string,
  appletId: string,
  since: number,
  limit: number
): Promise<PullResponse> {
  const changes = await db.query.syncChanges.findMany({
    where: and(
      eq(syncChanges.userId, userId),
      eq(syncChanges.appletId, appletId),
      gt(syncChanges.serverVersion, since)
    ),
    orderBy: (t, { asc }) => [asc(t.serverVersion)],
    limit: limit + 1, // fetch one extra to detect hasMore
  });

  const hasMore = changes.length > limit;
  const result = hasMore ? changes.slice(0, limit) : changes;

  return {
    changes: result.map(toChangeDTO),
    latestVersion: result.length > 0
      ? result[result.length - 1].serverVersion
      : since,
    hasMore,
  };
}
```

---

## 5. Conflict Resolution

### 5.1 Conflict Detection

A conflict occurs when:
1. Client pushes a change for record `R` with `baseVersion = V`
2. Server has a change for record `R` with `serverVersion > V`

This means another device modified the same record after this client last synced.

### 5.2 Resolution Strategies

The sync engine supports two resolution strategies, selectable per table:

| Strategy | How It Works | Best For |
|----------|-------------|----------|
| **Last-writer-wins (LWW)** | The change with the later `updatedAt` timestamp wins. If timestamps are equal, the server's version wins. | Simple fields where the latest value is always correct (e.g., task status, device state) |
| **Per-field merge** | Non-overlapping field changes are merged. Overlapping field changes use LWW on the individual field. | Records with many independent fields (e.g., a task where one device changes the title while another changes the priority) |

### 5.3 Last-Writer-Wins (Default)

```swift
// Core/Sync/ConflictResolver.swift
struct LWWConflictResolver: ConflictResolutionPolicy {
    func resolve(
        local: SyncChangeSet,
        remote: SyncChangeSet
    ) -> ResolvedChange {
        // Compare updatedAt timestamps
        let localTime = local.data["updatedAt"] as? Date ?? .distantPast
        let remoteTime = remote.data["updatedAt"] as? Date ?? .distantPast

        if localTime > remoteTime {
            return .useLocal(local)
        } else {
            return .useRemote(remote)
        }
    }
}
```

### 5.4 Per-Field Merge (Upgrade Path)

Per-field merge is more sophisticated and reduces data loss in multi-device scenarios:

```swift
struct FieldMergeConflictResolver: ConflictResolutionPolicy {
    func resolve(
        local: SyncChangeSet,
        remote: SyncChangeSet
    ) -> ResolvedChange {
        // Both are updates — merge at field level
        guard local.operation == .update, remote.operation == .update else {
            // For insert/delete conflicts, fall back to LWW
            return LWWConflictResolver().resolve(local: local, remote: remote)
        }

        var merged = remote.data  // start with remote as base
        let localFields = Set(local.data.keys)
        let remoteFields = Set(remote.data.keys)

        // Non-overlapping local fields: take local value
        for field in localFields.subtracting(remoteFields) {
            merged[field] = local.data[field]
        }

        // Overlapping fields: LWW per field using updatedAt
        for field in localFields.intersection(remoteFields) {
            if field == "updatedAt" { continue }
            // If the values differ, use the one from the later change
            let localTime = local.data["updatedAt"] as? Date ?? .distantPast
            let remoteTime = remote.data["updatedAt"] as? Date ?? .distantPast
            if localTime > remoteTime {
                merged[field] = local.data[field]
            }
            // else: keep remote (already in merged)
        }

        // Update the final updatedAt to the later of the two
        merged["updatedAt"] = max(
            local.data["updatedAt"] as? Date ?? .distantPast,
            remote.data["updatedAt"] as? Date ?? .distantPast
        )

        return .useMerged(merged)
    }
}
```

### 5.5 Conflict Notification

When a conflict is resolved automatically, the resolution is logged locally for diagnostics. For high-stakes conflicts (e.g., both devices changed the same task title to different values), the sync engine can optionally surface the conflict to the user via the event bus:

```swift
// Published on the event bus when a conflict requires user attention
SuperEvent.syncConflictDetected(SyncConflict(
    appletId: "todo",
    tableName: "task",
    recordId: "uuid",
    localValue: localData,
    remoteValue: remoteData,
    autoResolution: .usedRemote
))
```

Applets can subscribe to this event and show a UI for manual conflict resolution if desired. Notifications can aggregate unresolved conflicts.

### 5.6 Delete Conflicts

Deletes require special handling:

| Scenario | Resolution |
|----------|------------|
| Device A updates record, Device B deletes same record | **Delete wins.** The update is discarded. Rationale: explicit deletion is an intentional act. |
| Device A deletes record, Device B deletes same record | No conflict. Idempotent. |
| Device A inserts record, Device B has no knowledge | No conflict. Insert applied. |

Deleted records are preserved in the server change log as tombstones (operation = "delete") so that other devices learn about the deletion during pull.

---

## 6. Schema Considerations

### 6.1 Client vs. Server Schema Relationship

Client (SQLite/GRDB) and server (Postgres) schemas are **not identical** but are **structurally compatible**. The sync engine treats data as opaque JSON payloads — it does not interpret the contents of `data` fields beyond what is needed for conflict resolution (`updatedAt`).

| Aspect | Client (GRDB/SQLite) | Server (Postgres) |
|--------|---------------------|-------------------|
| Schema definition | Swift structs with `TableDefinition` | Drizzle schema definitions |
| Primary keys | UUID strings | UUID (native type) |
| Dates | ISO 8601 strings or `Double` (timeIntervalSince1970) | `TIMESTAMPTZ` |
| JSON fields | TEXT columns | `JSONB` columns |
| Migrations | GRDB `DatabaseMigrator` | Drizzle migrations |
| Sync metadata | `syncLog`, `syncCursor` tables | `sync_changes` table |

### 6.2 Required Columns for Synced Tables

Every table that participates in sync must include these columns:

```swift
// Client-side (GRDB)
try db.create(table: "task") { t in
    t.column("id", .text).primaryKey()          // UUID string, client-generated
    t.column("title", .text).notNull()
    t.column("priority", .text).notNull()
    // ... applet-specific columns ...
    t.column("createdAt", .datetime).notNull()   // required for sync
    t.column("updatedAt", .datetime).notNull()   // required for sync, used for LWW
    t.column("deletedAt", .datetime)             // soft delete for sync tombstones
}
```

```typescript
// Server-side (Drizzle)
export const tasks = pgTable('tasks', {
  id: uuid('id').primaryKey(),
  userId: uuid('user_id').notNull().references(() => users.id),
  title: text('title').notNull(),
  priority: text('priority').notNull(),
  // ... applet-specific columns ...
  createdAt: timestamp('created_at', { withTimezone: true }).notNull(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull(),
  deletedAt: timestamp('deleted_at', { withTimezone: true }),
});
```

### 6.3 Migration Coordination

Client and server migrations are **independent but coordinated** through a versioned contract:

1. **Schema version** is tracked per applet. The sync payload includes a `schemaVersion` field.
2. **Additive changes** (new columns, new tables) are non-breaking. The server ignores unknown fields in incoming payloads. The client ignores unknown fields in pulled changes.
3. **Breaking changes** (column renames, type changes) require a coordinated release:
   - Server deploys first, supporting both old and new schema versions.
   - Client update ships, writing in the new format.
   - After a migration window, server drops old schema support.

```json
{
  "clientId": "device-uuid",
  "baseVersion": 42,
  "schemaVersion": 3,
  "changes": [ ... ]
}
```

The server rejects pushes with a `schemaVersion` it does not support, returning a `426 Upgrade Required` response that tells the client to update the app.

---

## 7. Security

### 7.1 Transport Security

All sync traffic uses HTTPS (TLS 1.3). Certificate pinning is applied for the Super API domain to prevent MITM attacks.

### 7.2 Authentication

Sync endpoints require a valid JWT in the `Authorization` header. The token is obtained through the username/password authentication flow (see [AUTH.md](./AUTH.md)).

```
Authorization: Bearer eyJhbGciOiJFUzI1NiIs...
```

- **Access tokens** expire after 15 minutes.
- **Refresh tokens** are used to obtain new access tokens without re-authentication.
- The `AuthInterceptor` (see [CLIENT_SERVER.md](./CLIENT_SERVER.md)) handles token refresh transparently during sync.

### 7.3 Per-User Data Isolation

The server enforces strict per-user data isolation:

```typescript
// Every sync query is scoped to the authenticated user
const changes = await db.query.syncChanges.findMany({
  where: and(
    eq(syncChanges.userId, authenticatedUserId), // always filtered by user
    eq(syncChanges.appletId, appletId),
    gt(syncChanges.serverVersion, since)
  ),
});
```

- There is no API endpoint that returns data for a user other than the authenticated one.
- Row-level security (RLS) in Postgres provides a defense-in-depth layer.
- Server-side middleware validates that the `userId` in the JWT matches the request context.

### 7.4 Payload Security

- Sync payloads are **not end-to-end encrypted** in v1. Data is encrypted in transit (HTTPS) and at rest (Postgres disk encryption).
- **Future consideration:** For highly sensitive applets (e.g., a future notes applet), end-to-end encryption can be added at the applet level. The sync engine treats payloads as opaque bytes, so E2E encryption is transparent to the sync protocol.

### 7.5 Rate Limiting

Sync endpoints are rate-limited to prevent abuse:

| Endpoint | Limit |
|----------|-------|
| Push | 60 requests/minute per user |
| Pull | 120 requests/minute per user |
| Snapshot | 5 requests/hour per user |

---

## 8. Sync Frequency & Triggers

### 8.1 When Sync Happens

The `SyncScheduler` triggers sync based on multiple signals:

| Trigger | Behavior | Rationale |
|---------|----------|-----------|
| **App foreground** | Pull immediately, then push | User expects to see latest data when opening the app |
| **Connectivity restored** | Push queued changes, then pull | Flush offline changes as soon as possible |
| **After local write** | Debounced push (2-second delay) | Sync changes promptly without hammering the server during rapid edits |
| **Periodic background** | iOS `BGAppRefreshTask` every 15 minutes | Keep data fresh even when the app is backgrounded |
| **Push notification** | Silent push triggers pull | Server can notify clients when changes are available (from another device) |
| **Manual** | User taps "Sync Now" in settings | Escape hatch for users who want to force sync |

### 8.2 Sync Scheduler Implementation

```swift
// Core/Sync/SyncScheduler.swift
@Observable
final class SyncScheduler {
    private let syncEngine: SyncEngine
    private let networkMonitor: NetworkMonitor
    private var debounceTask: Task<Void, Never>?

    /// Called when the app enters foreground
    func onForeground() {
        Task { await syncEngine.syncAll() }
    }

    /// Called when a local write occurs in a synced table
    func onLocalChange(appletId: String) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await syncEngine.push(appletId: appletId)
        }
    }

    /// Called when network connectivity changes
    func onConnectivityChanged(isConnected: Bool) {
        guard isConnected else { return }
        Task { await syncEngine.syncAll() }
    }
}
```

### 8.3 Background Sync (iOS)

```swift
// Register background task in AppDelegate
BGTaskScheduler.shared.register(
    forTaskWithIdentifier: "com.super.sync.refresh",
    using: nil
) { task in
    let syncTask = task as! BGAppRefreshTask
    Task {
        await syncEngine.syncAll()
        syncTask.setTaskCompleted(success: true)
    }
    // Schedule next refresh
    scheduleNextSync()
}
```

### 8.4 Silent Push Notifications

When the server receives a push from device A, it can send a silent push notification to the user's other devices, prompting them to pull:

```typescript
// Server: after accepting a push
async function notifyOtherDevices(userId: string, sourceClientId: string) {
  const devices = await getDeviceTokens(userId);
  for (const device of devices) {
    if (device.clientId === sourceClientId) continue;
    await apns.send(device.token, {
      aps: { 'content-available': 1 },
      syncAppletId: appletId,
    });
  }
}
```

---

## 9. Data Types & Serialization

### 9.1 Wire Format

All sync payloads use **JSON** over HTTPS. Binary formats (Protocol Buffers, MessagePack) are not used in v1 to maximize debuggability and simplicity.

### 9.2 Type Mapping

| Swift Type | JSON Representation | Postgres Type | Notes |
|------------|-------------------|---------------|-------|
| `UUID` | `"550e8400-e29b-41d4-a716-446655440000"` | `UUID` | String in JSON, native UUID in Postgres |
| `Date` | `"2026-03-14T10:30:00.000Z"` | `TIMESTAMPTZ` | Always ISO 8601, always UTC |
| `Bool` | `true` / `false` | `BOOLEAN` | |
| `Int` / `Int64` | `42` | `INTEGER` / `BIGINT` | |
| `Double` | `3.14` | `DOUBLE PRECISION` | |
| `String` | `"hello"` | `TEXT` | |
| `Data` (binary) | Base64-encoded string | `BYTEA` | Avoid syncing large blobs; use file sync instead |
| `enum` (string-backed) | `"high"` | `TEXT` | Enums are serialized as their raw string values |
| `[String]` / nested JSON | `["a", "b"]` or `{...}` | `JSONB` | Complex nested structures stored as JSONB |

### 9.3 Null Handling

- `null` in JSON means "this field was explicitly set to nil" (e.g., clearing a due date).
- Absent field means "this field was not changed" (relevant for partial updates).

This distinction is critical for per-field merge: the sync engine must differentiate between "the client cleared this field" and "the client did not touch this field."

```swift
// Use a wrapper to distinguish null from absent
enum SyncValue<T: Codable>: Codable {
    case set(T)       // field was changed to this value
    case cleared      // field was explicitly set to nil
    // absent from the payload = not changed
}
```

### 9.4 Large Binary Data

Binary blobs (images, attachments) are **not synced through the change set protocol**. Instead:

1. The applet uploads the blob to object storage (S3 or equivalent) via a separate upload endpoint.
2. The sync payload contains only the blob's URL/key.
3. Other devices download the blob on demand when they encounter the URL.

This keeps sync payloads small and fast.

---

## 10. Applet Opt-In

### 10.1 The `SyncableApplet` Protocol

An applet registers for sync by conforming to `SyncableApplet`. This is the only integration point — the sync engine handles everything else.

```swift
// Core/Sync/SyncableApplet.swift
protocol SyncableApplet {
    /// Unique identifier for this applet in sync (e.g., "todo")
    static var syncAppletId: String { get }

    /// Tables to sync, with their conflict resolution policies
    var syncConfiguration: SyncConfiguration { get }

    /// The GRDB DatabaseWriter for this applet's database
    var databaseWriter: any DatabaseWriter { get }
}

struct SyncConfiguration {
    let tables: [SyncTableConfig]
    let schemaVersion: Int
}

struct SyncTableConfig {
    let tableName: String
    let primaryKey: String
    let conflictPolicy: ConflictResolutionPolicy
    let recordType: any SyncableRecord.Type
}

// Example: ToDo opt-in
extension ToDoApplet: SyncableApplet {
    static var syncAppletId: String { "todo" }

    var syncConfiguration: SyncConfiguration {
        SyncConfiguration(
            tables: [
                SyncTableConfig(
                    tableName: "project",
                    primaryKey: "id",
                    conflictPolicy: .lastWriterWins,
                    recordType: Project.self
                ),
                SyncTableConfig(
                    tableName: "task",
                    primaryKey: "id",
                    conflictPolicy: .perFieldMerge,
                    recordType: ToDoTask.self
                ),
                SyncTableConfig(
                    tableName: "label",
                    primaryKey: "id",
                    conflictPolicy: .lastWriterWins,
                    recordType: Label.self
                ),
            ],
            schemaVersion: 1
        )
    }
}
```

### 10.2 Registration at App Startup

The shell registers all syncable applets with the sync engine during app initialization:

```swift
// In the Shell's app setup
let syncEngine = SyncEngine(
    httpClient: httpClient,
    networkMonitor: networkMonitor
)

// Register applets that support sync
for applet in appletRegistry.allApplets {
    if let syncable = applet as? SyncableApplet {
        syncEngine.register(syncable)
    }
}
```

### 10.3 Per-Applet Sync Toggle

Users can enable/disable sync per applet in Shell Settings. When sync is disabled for an applet:

- The `SyncChangeTracker` stops recording changes for that applet.
- Existing unsynced changes in `syncLog` are preserved (not deleted) in case the user re-enables sync.
- The sync cursor is preserved so re-enabling sync resumes from where it left off.

---

## 11. Reusability

### 11.1 Extraction as a Standalone Swift Package

The sync engine lives in the `Core/Sync` directory and has zero dependencies on Super-specific types. It depends only on:

- **GRDB** — for SQLite database access
- **Foundation** — for networking, JSON, dates

This makes it extractable as a standalone Swift Package:

```
SuperSync/
├── Package.swift
├── Sources/
│   └── SuperSync/
│       ├── SyncEngine.swift
│       ├── SyncScheduler.swift
│       ├── SyncClient.swift
│       ├── ChangeTracker.swift
│       ├── ConflictResolver.swift
│       ├── SyncCursorStore.swift
│       ├── SyncLogEntry.swift
│       ├── Protocols/
│       │   ├── SyncableApplet.swift
│       │   ├── SyncableRecord.swift
│       │   └── ConflictResolutionPolicy.swift
│       └── Models/
│           ├── SyncChangeSet.swift
│           ├── PushRequest.swift
│           ├── PushResponse.swift
│           ├── PullResponse.swift
│           └── SyncConfiguration.swift
└── Tests/
    └── SuperSyncTests/
        ├── ChangeTrackerTests.swift
        ├── ConflictResolverTests.swift
        ├── SyncEngineIntegrationTests.swift
        └── Fixtures/
```

### 11.2 What Another App Needs to Adopt This

Any app that wants to use the sync engine needs to:

1. Add the `SuperSync` Swift Package dependency.
2. Conform its data types to `SyncableRecord`.
3. Conform its module/feature to `SyncableApplet`.
4. Deploy the server-side sync module (provided as a reference TypeScript implementation).

The app does **not** need to use Super, the event bus, or any other Super component.

### 11.3 Server-Side Reusability

The server sync module is similarly independent. It is a Hono route group that can be mounted in any TypeScript/Node.js backend:

```typescript
// In any Hono app
import { syncRoutes } from '@super/sync-server';

app.route('/api/v1/sync', syncRoutes({
  database: db,
  auth: authMiddleware,
}));
```

---

## 12. Testing Strategy

### 12.1 Unit Tests

| Component | Test Approach |
|-----------|---------------|
| **ChangeTracker** | In-memory GRDB database. Perform writes, assert `syncLog` entries are correct. |
| **ConflictResolver (LWW)** | Pure function tests with fabricated change sets. Assert the correct winner. |
| **ConflictResolver (per-field)** | Tests with overlapping and non-overlapping field changes. Assert merged output. |
| **SyncCursor** | Assert cursor advances correctly after push/pull. |
| **Sync log compaction** | Insert entries, mark some synced, compact, assert only unsynced remain. |

### 12.2 Snapshot Testing with GRDBSnapshotTesting

Database state after sync operations is verified using [GRDBSnapshotTesting](https://github.com/groue/GRDBSnapshotTesting):

```swift
import GRDBSnapshotTesting
import InlineSnapshotTesting

@Test func pullAppliesRemoteInsert() throws {
    let dbQueue = try DatabaseQueue.inMemory()
    // Set up schema and sync engine
    let engine = SyncEngine(db: dbQueue, ...)

    // Simulate a pull that returns a new task
    let remoteChanges = [
        PullChange(
            serverVersion: 1,
            tableName: "task",
            recordId: "abc-123",
            operation: .insert,
            data: ["id": "abc-123", "title": "From other device", "priority": "high"]
        )
    ]
    try engine.applyRemoteChanges(remoteChanges, to: dbQueue)

    // Assert the database state matches expected snapshot
    assertSnapshot(of: dbQueue, as: .dumpTables(["task"]))
}
```

### 12.3 Simulated Conflict Scenarios

A dedicated test suite covers every conflict scenario:

```swift
@Test func conflictLWW_localNewer_localWins() async throws {
    // Local change at T+2, remote change at T+1
    // Assert: local value is kept
}

@Test func conflictLWW_remoteNewer_remoteWins() async throws {
    // Local change at T+1, remote change at T+2
    // Assert: remote value is applied
}

@Test func conflictFieldMerge_nonOverlapping_merges() async throws {
    // Local changes: {title: "new title"}
    // Remote changes: {priority: "urgent"}
    // Assert: merged result has both changes
}

@Test func conflictFieldMerge_overlapping_LWWPerField() async throws {
    // Local changes: {title: "A", priority: "high"} at T+2
    // Remote changes: {title: "B", status: "done"} at T+1
    // Assert: title = "A" (local newer), status = "done" (only remote), priority = "high" (only local)
}

@Test func conflictDeleteVsUpdate_deleteWins() async throws {
    // Local: update record R
    // Remote: delete record R
    // Assert: record R is deleted locally
}

@Test func fullSyncFromScratch_buildsCorrectState() async throws {
    // Empty local DB, server has 1000 records across 3 tables
    // Assert: local DB matches server state exactly
}
```

### 12.4 Integration Tests

End-to-end sync tests run against a real Postgres instance (via Docker in CI):

1. Two simulated clients (two in-memory GRDB databases) sync through a real server.
2. Client A writes data, syncs. Client B syncs, verifies it received Client A's data.
3. Both clients modify the same record, sync, verify conflict resolution produced the correct result on both sides.

### 12.5 Network Condition Testing

- **Offline queue:** Write 100 changes offline, restore connectivity, verify all changes sync successfully.
- **Partial sync failure:** Simulate a network error mid-push. Verify the client retries only the unacknowledged changes.
- **Server error:** Simulate 500 responses. Verify exponential backoff and eventual retry.

---

## 13. Open Questions

These are decisions that need further investigation or discussion before implementation:

| # | Question | Options | Leaning |
|---|----------|---------|---------|
| 1 | **Should the server store the full change history or compact it?** | (a) Keep all changes forever (audit trail, replay) (b) Compact to latest state per record after N days | (a) for now — storage is cheap, audit trail is valuable. Compact later if needed. |
| 2 | **How do we handle clock skew between devices?** | (a) Rely on `updatedAt` (client clock) for LWW (b) Use server-assigned timestamps for LWW ordering | (b) — client clocks are unreliable. Use server timestamp as tiebreaker when client timestamps are within a tolerance window. |
| 3 | **Should sync be all-or-nothing per push, or accept partial?** | (a) Atomic: reject entire push if any change conflicts (b) Partial: accept non-conflicting, reject conflicting | (b) — partial acceptance is more forgiving and reduces re-sync overhead. |
| 4 | **Do we need a device registration system?** | (a) Track registered devices per user (b) Stateless — any authenticated request is valid | (a) — needed for silent push notifications to other devices, and for "last synced from" diagnostics. |
| 5 | **How do we handle applet uninstall + reinstall?** | (a) Full re-sync from server (b) Preserve sync cursor locally even after uninstall | (a) — if the user uninstalls an applet, local data is deleted. Reinstall triggers a full sync. |
| 6 | **Should we support selective table sync?** | (a) All-or-nothing per applet (b) User can choose which tables sync (e.g., sync tasks but not projects) | (a) for v1 — per-table toggle adds UI complexity with minimal user benefit. |
| 7 | **WebSocket for real-time sync?** | (a) Add WebSocket channel for instant push-to-other-devices (b) Silent APNs push + pull is sufficient | (b) for v1 — APNs is simpler, no persistent connection to manage. Revisit if latency becomes a complaint. |
| 8 | **End-to-end encryption?** | (a) Encrypt sync payloads client-side before push (b) Trust server-side encryption (TLS + disk encryption) | (b) for v1 — E2E encryption complicates search, conflict resolution, and server-side processing. Add as opt-in per applet later. |
| 9 | **Multi-user sync (shared lists)?** | Entirely new dimension — shared ownership, permissions, real-time collaboration | Out of scope for v1. Architecture should not preclude it but does not need to support it. |

---

## Appendix A: Server Database Schema

```sql
-- Core sync infrastructure tables

CREATE TABLE sync_changes (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id),
    applet_id       TEXT NOT NULL,
    table_name      TEXT NOT NULL,
    record_id       TEXT NOT NULL,
    operation       TEXT NOT NULL CHECK (operation IN ('insert', 'update', 'delete')),
    data            JSONB,
    client_id       TEXT NOT NULL,
    client_timestamp TIMESTAMPTZ NOT NULL,
    server_version  BIGINT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index for pull queries: "give me changes since version X for this user+applet"
CREATE INDEX idx_sync_changes_pull
    ON sync_changes (user_id, applet_id, server_version);

-- Index for conflict detection: "has this record changed since version X?"
CREATE INDEX idx_sync_changes_conflict
    ON sync_changes (user_id, applet_id, table_name, record_id, server_version);

-- Sequence for server versions (per user+applet)
CREATE TABLE sync_version_counters (
    user_id    UUID NOT NULL REFERENCES users(id),
    applet_id  TEXT NOT NULL,
    version    BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, applet_id)
);

-- Device registration for push notifications
CREATE TABLE user_devices (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id),
    client_id   TEXT NOT NULL UNIQUE,
    device_token TEXT,          -- APNs token
    platform    TEXT NOT NULL,  -- "ios", "macos"
    last_seen   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

## Appendix B: Sync State Machine

```
                    ┌──────────┐
                    │   IDLE   │
                    └────┬─────┘
                         │ trigger (foreground / connectivity / timer / write)
                         ▼
                    ┌──────────┐
              ┌─────│ PULLING  │
              │     └────┬─────┘
              │          │ pull complete
        error │          ▼
              │     ┌──────────┐
              │     │ APPLYING │──── apply remote changes locally
              │     └────┬─────┘
              │          │ apply complete
              │          ▼
              │     ┌──────────┐
              │     │ PUSHING  │
              │     └────┬─────┘
              │          │ push complete
              │          ▼
              │     ┌──────────────┐
              │     │ COMPACTING   │──── clean up synced entries
              │     └────┬─────────┘
              │          │
              ▼          ▼
         ┌──────────┐ ┌──────────┐
         │  BACKOFF  │ │   IDLE   │
         │ (retry)   │ └──────────┘
         └──────────┘
```

The sync engine maintains this state machine per applet. Multiple applets can sync concurrently (each on its own `Task`), but a single applet never runs two sync cycles simultaneously.
