# Integration Test Audit — September 2026

Integration tests run inside the same four Swift package targets as unit tests. This audit reduces repeated database setup and corpus decoding, and strengthens assertions at real SQLite, URLSession, and session/persistence boundaries. It changes tests and documentation only; production code, CI configuration, SQL snapshot baselines, and the 623-image visual inventory remain unchanged.

## Scope

Baseline: merged main `dac76b09`. Reviewed database migrations, repositories/queries, bundled-resource loading, Core HTTP transport, event-bus/session flows, and narration filesystem coverage. Tests are classified by the dependencies they exercise, not their filenames. A real in-memory SQLite database is integration coverage; `InMemoryKeychainClient` is a unit-test double rather than Apple Keychain integration.

The audit preserves seeded historical upgrades, foreign-key/uniqueness behavior, actual repository/query execution, full chapter parity, verse-contiguity regressions, and meaningful cancellation cases. Similar-looking tests against different provider protocols, query entry points, or disk/index layers remain distinct contracts.

## Removed or consolidated coverage

Paths below are relative to each package's `Tests/<Package>Tests` directory. Seventeen fresh-database schema inventory functions were redundant with unchanged SQL text snapshots. The snapshots include table names, full column declarations, defaults, foreign keys, indexes, and uniqueness, so they detect more schema drift than the removed name/column checks.

| Removed or consolidated functions | Retained contract |
|---|---|
| Chat `Database/ChatDatabaseMigrationTests`: `v1CreatesEverySchemaTable`, `v1CreatesEveryExpectedIndex`, `messageColumnsMatchRecordShape`, `v4AddsKindColumnAndNullableURLAndKeyRef`, `v5AddsConversationKindWithUserDefault`, `v6AddsNullableSearchBackendColumn`, `v8AddsNullableThinkingSignatureColumn`, `v9AddsNullableThinkingModelIdColumn`; `MessageAttachmentsMigrationTests.v2AddsAttachmentsJSONColumnToMessageTable` | `ChatDatabaseMigrationTests.migratedSchemaSnapshot`; seeded v4/v5/v8/v9/v10 upgrades, selected-model constraint behavior, cascades, and actual attachment round trips remain. |
| Bible `Database/BibleDatabaseTests`: `v1CreatesSchema`, `v2CreatesHighlightSchema`, `v2CreatesHighlightIndexes`, `annotationSchemaHasSummary`, `annotationIndexesSurviveTheV9Rebuild` | `BibleSchemaSnapshotTests.schemaMatchesBaseline`; live SQLite uniqueness and seeded legacy annotation upgrade remain. |
| Todo `Database/TodoDatabaseMigrationTests`: `v1CreatesEverySchemaTable`, `v1CreatesExpectedIndexes`, `v1TaskLabelCarriesSyncColumns` | `TodoSchemaSnapshotTests.v1SchemaMatchesBaseline`; both foreign-key cascades and case-insensitive partial uniqueness behavior remain. |
| Bible `Database/BibleTextDatabaseTests.opensAndPopulated` | `allTranslationsPresent` requires more than 30,000 verses in each of four translations, implying the former aggregate lower bound. Real database opening is exercised by every retained artifact test. |
| Bible `BibleTextDatabaseTests.chapterTablePopulated`, `chapterBlobDecodesToBibleChapter` | Exhaustive `DatabaseBibleTextLoaderParityTests.everyChapterMatches` covers every expected chapter, exact JSON chapter identities, equality through the production loader, and exactly 1,189 stored chapters per translation. This strengthens the former sampled equality and loose total-count bounds. |
| Bible `TextSources/BundledBibleTextLoaderTests.verseNumbersAreContiguous` | Its full-corpus verse-contiguity check and documented textual-variant exception list now run inside `everyChapterMatches`, reusing each already-decoded JSON book. |
| Chat `Orchestration/ChatSessionTests`: `textDeltasAccumulateAndAssistantSavesOnceOnMessageComplete`, `intermediateTextDeltasNeverWriteToDatabase`, `assistantMessageSavedEventCarriesPersistedRow`, `isStreamingFlipsBackToFalseAfterTurnCompletes` | One paused-provider lifecycle checks intermediate database state, exact text/thinking events, one assistant-save event, equality with the persisted row, complete content/token count, and final inactivity. |
| Core `HTTP/URLSessionHTTPClientTests.streamsSingleChunkSuccessfully` | `streamsMultipleChunksInOrder` retains the exact assembled response-body contract. |

The existing corpus check becomes four independent translation argument cases. It still compares all **4,756 chapters**. It decodes **264 JSON books instead of 528** across the two former passes; there is no shared mutable cache and no reduced sample. Flat verse/coalescing and FTS search checks remain separate because those tables are different generated representations.

## Added and strengthened integration contracts

- **Bible malformed storage and lookup isolation:** insert invalid JSON and structurally invalid paragraph JSON directly into SQLite; require the exact domain error with chapter identity. Seed colliding book/chapter/translation keys and assert the exact chapter for each, plus an absent translation.
- **Bible historical data preservation:** the seeded v8-to-current migration still proves legacy annotations and their ledger are intentionally cleared. It now compares the reader position, highlight, bookmark, and user note before/after, ensuring unrelated user content survives.
- **Todo atomic replacement:** an SQLite trigger rejects deletion after the replacement's insert has run. Exact join rows and timestamps must roll back, the sibling task must survive, and a subsequent replacement must work once the trigger is removed.
- **Todo idempotence and query isolation:** duplicate label inputs and repeated replacements preserve one row and its original timestamps. Bulk lookup excludes unrequested tasks and missing IDs. The actual `ActiveTasksRequest.fetch` excludes tombstoned join rows while retaining the task and its active label.
- **Chat streaming persistence:** the provider stays open while the test consumes each session broadcast and reads real GRDB. A premature upsert can no longer hide behind a correct final row count. Finishing the provider and draining the session verifies the final persisted record and event together.
- **Chat checkpoints:** a trigger rejecting a replacement verifies rollback of the previous live checkpoint's demotion. Selective deletion and empty input preserve unrelated history and the sibling conversation.
- **Chat legacy model upgrade:** compare all nine preexisting fields for distinct selected/unselected records across the v4 table rebuild, instead of checking only the new provider discriminator.
- **Chat shutdown:** keep two actual sessions active in cancellation-aware tools, call shutdown, and check completed cancellation writes and inactivity before any extra drain. Both streams end with cancellation and subsequent lookups create fresh sessions.
- **Core HTTP failures:** short and oversized multi-chunk error bodies yield no successful stream content; errors preserve the trimmed body and the exact 8,192-byte prefix limit.
- **Core HTTP cancellation:** replace an early-break smoke test that never observed cancellation with a held-open URLProtocol response, explicit start/stop signals, and consumer cancellation. The test deadline precedes URLSession's natural timeout, so timeout cannot masquerade as successful cancellation.
- **Core remote tool request:** inspect the actual serialized request's tool ID/input, endpoint, method, content type, and nondefault timeout, as well as its decoded response.

## Runtime and validation

Three isolated warm executions using the same pinned Xcode 26.4.1 / `17E202` toolchain:

| Corpus checks | Test execution times | Median |
|---|---|---|
| Original equality + separate contiguity pass | 0.706, 0.682, 0.661 s | 0.682 s |
| Combined exhaustive translation cases | 0.304, 0.323, 0.332 s | 0.323 s |

The median is **52.6% lower** for these checks. This measures test execution, excluding compilation and SwiftPM startup. Consolidation and translation-level parallelism both contribute. It is not a claim of equivalent end-to-end CI savings: macOS queue time and compilation remain much larger costs.

Run every affected package with:

```sh
DEVELOPER_DIR='/Applications/Xcode 26.app/Contents/Developer' \
  swift test --package-path Packages/<Package> --parallel \
  --enable-code-coverage -Xswiftc -warnings-as-errors
```

Baseline reported counts were Core 318, Chat 1,103, Bible 835, and Todo 87: **2,343 total**. Parameterized functions count once in these Swift Testing totals; argument cases are additional executions. These totals combine unit/integration suites and exclude UIKit-only tests. Current main included additional tests merged since the prior unit audit.

Final full runs passed with **Core 317, Chat 1,093, Bible 827, and Todo 87: 2,324 reported tests**. Changed-file SwiftLint passed in CI's non-strict mode with six preexisting warnings and no new violations. `git diff --check` passed. All changes are nonvisual and runnable on macOS; no UIKit-only test behavior changed.

After rebasing onto the repository snapshot rollback in main `ba1161b1` (PR #354), all four complete package suites passed again with the same counts and pinned toolchain. The integration-test patch applied unchanged. The rebased PR retains the 623 checked-in image baselines and default comparisons; its required visual checks are `ios-test` and `native-previews`, with no external Argos gate.

Six new focused test functions cover malformed stored chapters, Todo replacement rollback/idempotence and query tombstones, and Chat checkpoint rollback/deletion. Other new assertions replace or strengthen existing functions. After consolidations and removals, the reported package total is 19 lower.

Eighteen deliberate negative controls were detected: malformed-row suppression, omitted book isolation, lost migration notes, a synthetic undocumented verse gap, missing Todo replacement transaction, unscoped bulk lookup, rewritten idempotent timestamps, visible tombstoned joins, missing checkpoint transaction, unscoped checkpoint deletion, premature assistant persistence both before and after the text broadcast, omitted shutdown draining, lost legacy model metadata, oversized error buffering, leaked HTTP error chunks, omitted remote-tool input, and omitted transport cancellation. The last control reached the test's one-minute failure deadline; ordinary cancellation completes immediately. All other controls failed behavioral assertions. Compiler failures were not accepted as detections.

Local logs and temporary mutation scripts live in the ignored `.build/integration-test-audit/` directory. Every mutation is restored before final validation; no generated images or fixture changes are committed.

## Retained limits and follow-ups

- The real narration filesystem cache already has distinct reopen, eviction, cancellation, foreign-file preservation, and atomic-staging tests. Its fault doubles cover additional actor-accounting branches; those are not redundant with physical disk behavior.
- Apple Keychain integration remains a gap: existing tests use an in-memory implementation. A signed test host with a unique disposable service namespace is needed to verify real Keychain behavior safely; the repository currently has no app-target XCTest target.
- GRDBQuery tests exercise actual SQL through `fetch`; they do not establish every SwiftUI observation lifecycle. The visual inventory is unchanged.
- The flat verse/FTS artifact tests sample coalescing/search behavior; full structured-chapter parity is not a substitute for exhaustive flat-verse/index validation. That broader integrity work was not added to the default suite here.
- No suite removal implies complete coverage of every behavior. This audit targets concrete duplication and missed assertions, without lowering coverage floors or adding network/provider dependencies.
