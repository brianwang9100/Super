# Todo

- Persisted rows carry `createdAt`, `updatedAt`, and `deletedAt?` for future sync; see [SYNC.md §6.2](../../docs/SYNC.md). Records explicitly list `TableRecord` and also conform to `Equatable, Identifiable`.
- Test GRDBQuery requests through `Request.fetch(_:)`; view snapshots cover reactive binding.
- `CollidingLabelRepository` is the deterministic fixture for concurrent label creation: its save throws and its lookup returns the raced row.
