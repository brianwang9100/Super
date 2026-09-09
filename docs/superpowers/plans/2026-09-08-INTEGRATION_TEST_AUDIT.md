# Integration Test Audit Implementation Plan

**Goal:** Reduce duplicated integration-test work and strengthen missing boundary contracts without reducing corpus, migration, persistence, or concurrency protection.

**Architecture:** Keep integration tests in their existing Swift package targets. Use real isolated SQLite databases, local filesystem fixtures, the real event bus, and URLProtocol-controlled networking; external services remain stubbed. Production changes are limited to bugs reproduced by new regressions.

**Tech stack:** Swift Testing, GRDB/GRDBSnapshotTesting, Foundation URLSession, SwiftPM, Xcode 26.4.1.

**Requirements:** User's integration audit request; `AGENTS.md`, `docs/TESTING.md`, and the retained integration inventory in `docs/UNIT_TEST_AUDIT.md`.

## Constraints and risks

- Work only in `/Users/bwang/.codex/worktrees/90d8/Super`, branch `codex/integration-test-audit`, based on merged main `dac76b09`.
- Remove a check only when retained assertions cover its contract. Schema SQL snapshots can replace fresh-schema name/column/index enumeration, but cannot replace seeded historical upgrades, foreign-key behavior, query semantics, or transaction guarantees.
- Preserve all 4,756 Bible chapter comparisons and verse-contiguity rules. Consolidate repeated fixture decoding rather than sampling fewer books. Keep the flat verse/FTS tests, which cover a separate representation.
- No mutable shared fixtures, sleeps/yield polling, or logic-suite serialization. URLProtocol registrations remain unique per test and are cleaned up.
- Visual inventory stays 623; no visual pipeline, runner, build-system, or coverage-floor changes.
- Package test counts include both unit and integration functions; report them honestly. Compare repeated isolated measurements under the same toolchain, and distinguish test execution from compilation/CI queue time.

## 1. Baseline and coverage map

- [x] Inspect database/repository/query, resource-loading, HTTP, event-bus and session integration tests across Core, Chat, Bible, and Todo; compare against production branches.
- [x] Record baseline package results with `DEVELOPER_DIR='/Applications/Xcode 26.app/Contents/Developer' swift test --package-path Packages/<Package> --parallel --enable-code-coverage -Xswiftc -warnings-as-errors` in `.build/integration-test-audit/`.
- [x] Review this plan independently before edits. Record concrete additions identified by the parallel read-only Core/Chat audits before implementing them.

## 2. Remove duplicate setup and schema inventories

Files: Bible/Todo `Tests/*Tests/Database/*Tests.swift`, Chat `Tests/ChatTests/Database/ChatDatabaseMigrationTests.swift` and `MessageAttachmentsMigrationTests.swift`; retain existing SQL text snapshot baselines.

- [x] Verify each SQL snapshot includes the actual tables, columns, index definitions, and uniqueness currently checked by fresh-schema enumeration tests. Remove only redundant enumeration functions; document every removed name and its retained test.
- [x] Keep seeded upgrade tests and constraint/cascade behavior. Strengthen assertions if a purported migration test only checks the final shape or if unrelated user data preservation is missing.
- [x] In Bible `TextSources/DatabaseBibleTextLoaderParityTests.swift` and `BundledBibleTextLoaderTests.swift`, perform chapter parity and verse-contiguity checks during one JSON-book decode pass. Preserve contextual failures and the textual-variant exception list. Assert exact chapter identity/counts to avoid nil/nil or skipped-canon passes.
- [x] Remove sampled structured-chapter equality in `BibleTextDatabaseTests` only after confirming the exhaustive production-loader test covers it. Retain flat verse and FTS coverage; merge total verse count into per-translation checks if logically implied.

## 3. Fill integration gaps

- [x] Bible `TextSources/DatabaseBibleTextLoaderTests.swift`: insert malformed JSON directly in an isolated chapter table and require the exact `BibleTextLoaderError.malformedResource` rather than nil or an arbitrary error. Add same-number rows across books/chapters/translations to prove all lookup predicates isolate data.
- [x] Todo `Repositories/TaskLabelRepositoryTests.swift`: exercise atomic set replacement with an SQLite trigger that deterministically aborts deletion after insertion; require rollback restores exact join rows/timestamps and leaves a second task unchanged. Cover duplicate label input idempotence using raw persisted rows, plus bulk lookup restricted to requested task IDs with an unrelated seeded task.
- [x] Core HTTP: strengthen non-2xx streaming coverage to assert no body chunks escape and the error contains the capped body. Replace the early-break test's ineffective cancellation assertion with a controlled held-open URLProtocol fixture that observes transport stop, if achievable without changing production behavior or timing waits.
- [x] Chat `Orchestration/ChatSessionTests.swift`: replace `intermediateTextDeltasNeverWriteToDatabase`'s final-row-count-only assertion with a paused provider and a consumed broadcast signal; query the real database before `.messageComplete`, then verify final persistence after releasing the provider.
- [x] Chat `Repositories/CompactionCheckpointRepositoryTests.swift`: install a temporary SQLite `BEFORE INSERT` trigger that rejects a replacement checkpoint after the previous live checkpoint is demoted; assert the old checkpoint and its live status survive rollback exactly.
- [x] Do not count in-memory Keychain doubles as Apple Keychain integration coverage. Preserve filesystem narration cache tests that exercise distinct physical-write and index/cancellation boundaries. Event-bus subscriber lifecycle is a potential follow-up only if a deterministic removal seam can be justified; do not add production seams solely to reduce trivial test counts.

Additional confirmed coverage: Todo's `ActiveTasksRequest` now excludes tombstoned joins while preserving active labels/tasks; Bible's seeded v9 upgrade preserves unrelated reader position, highlight, bookmark, and user-note records. The Core remote-tool test now verifies its serialized request. Chat shutdown now drains two active tool sessions, using the existing cancellation-aware entry signal. The independent plan review approved the schema/corpus approach and the Chat/HTTP extensions before implementation.

## 4. Verification and delivery

- [x] Run each affected focused suite; reproduce newly discovered bugs before any production fix. Use temporary negative controls for the new contract assertions and restore all mutations.
- [x] Benchmark the old/new combined Bible corpus checks with three isolated warm executions each, including the same retained contiguity coverage.
- [x] Run every affected package in full with coverage and warnings-as-errors, then lint changed Swift files and `git diff --check`. Use simulator verification if UIKit-only behavior changes.
- [x] Write `docs/INTEGRATION_TEST_AUDIT.md` with scope, removal-to-retained-test mapping, additions, measured timings, count changes, validation, and limits.
- [x] Obtain a separate independent change review and address actionable findings, repeating affected validation.
- [ ] Create a draft PR using the repository template, request Codex review, and monitor review + CI every 10 minutes. After explicit approval of the current head and the six required checks (`build`, `lint`, `gitleaks`, `ios-test`, `swift-test`, `native-previews`) passing, mark ready, enable auto-merge without bypassing protections, verify merge, and stop monitoring. PR #354 retired the external Argos gate; preserve the repository snapshot comparisons and all 623 baselines.
