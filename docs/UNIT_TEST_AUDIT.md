# Unit Test Audit — September 2026

The unit suites contain some redundant checks and weak assertions, but removing large numbers of tests is not supported by the measured runtime. Compilation dominates the Swift CI jobs. This audit removes 13 redundant or implementation-only test functions, adds focused missing behavior coverage, replaces real copy timers with deterministic signals, and allows updated Swift build caches to be saved.

## Scope and evidence

Reviewed the four package inventories, timing logs, production-source coverage, expensive fixtures, and unit contracts for models, parsing, tools, orchestration, and view models. Candidates were compared against implementation branches and retained assertions; this is not a claim that every possible behavior is covered. Tests were classified by their dependencies, not their directory: a model test that opens the bundled text database is integration coverage.

The baseline is commit `30ce9d50`. The completed [Swift Tests run 34272510576](https://github.com/brianwang9100/Super/actions/runs/34272510576) used the preceding Argos revision and reported the same package test counts as the local baseline:

| Package | Reported tests before | CI compilation | CI test execution |
|---|---:|---:|---:|
| Core | 320 | 105.25 s | 0.245 s |
| Chat | 1,101 | 375.62 s | 5.299 s |
| Bible | 822 | 196.07 s | 6.516 s |
| Todo | 84 | 92.75 s | 0.198 s |

These are complete macOS package runs, including existing integration tests and excluding UIKit-only fixtures. Swift Testing's reported test counts count parameterized functions once; their argument cases are additional executions. Do not interpret the table as a pure-unit-only count or add concurrent test durations together.

Every package restored an exact cache key ending in its package name, then reported that the cache would not be saved because the primary key already existed. The key hashed only an absent, untracked `Package.resolved`. The Swift workflow now hashes package manifests, sources, tests and resources, the Core dependency, and the workflow, with architecture/toolchain/package boundaries and a matching restore prefix. Changed inputs can restore an earlier build and save the rebuilt outputs under a new key. This follows [the cache action's key and restore behavior](https://github.com/actions/cache#usage).

The cache change enables refresh; it does not prove that stale cache contents caused all compilation time. Fresh checkout timestamps and SwiftPM cache portability can still force rebuilding. More distinct keys also use more cache space and can increase eviction. Compare cache restore/save messages and compilation durations across subsequent CI runs before attributing savings.

## Removed checks and retained contracts

Paths below are relative to each package's `Tests/<Package>Tests` directory.

| Removed test functions | Why removal preserves useful coverage |
|---|---|
| Core `CoreTests.corePackageIsReachable`; Chat `ChatTests.chatPackageIsReachable`, `chatLinksCore` | These pin placeholder `0.0.1` constants or package linkage. Compiling the behavioral suites already checks linkage. Version constant access is intentionally no longer a coverage target. |
| Core `LLM/LLMProviderKindTests.shippedAdaptersAreBuildable`, `allCasesResolve` | `allKnownKindsAreCurrentlyBuildable` already checks every case's adapter flag and fails if evaluation traps. |
| Core `Events/RecordReferenceTests.equalInstancesCompareEqual` | Synthesized equality is exercised by the retained complete Codable round trip; distinct identity and every stored field remain covered. |
| Chat `Models/MessageRoleTests.roundTripsThroughLLMRoleForEveryCase`, `allCasesIsExhaustive` | Retain explicit forward/reverse mappings. The persisted raw-value assertion now checks the complete ordered list, covering its count too. |
| Chat `ChatVerbosityTests.allCasesIsExhaustive` | The retained display-name check now asserts the entire ordered list. Ranking and inclusive comparison tests remain. |
| Chat `Models/ModelConfigurationRecordTests.defaultsToNilSearchBackend` | This passed an explicit `nil`, so it did not test a default. `projectsSearchBackend` retains nil and non-nil projection assertions. |
| Bible `Models/BibleBookmarkColorTests.paletteHasSixColours`, `BibleHighlightColorTests.paletteHasFiveColours` | Existing complete display-name list and the strengthened complete raw-value list respectively imply these counts. Tint and compatibility checks remain. |
| Bible `Models/BibleChapterCoalescedVersesTests.headingsSkipped` | `coalescesFragments` already includes a heading and asserts exact resulting verse numbers and text. |

## Strengthened and added coverage

- **Copy confirmation:** Chat injects the sleep closure using the existing Core timer convention and keeps its production 1.2-second delay. Separate gates let the tests observe cancellation of the first task while the second is still suspended. Core's copy-controller tests now observe cancellation and release their waits instead of leaving 60-second sleeps pending.
- **Compaction threshold:** Replace a 400,000-character assembler fixture with small `ContextAssembly` values just below, exactly at, and above each configured threshold. Assembler rollup/calibration tests remain separate.
- **Token accounting:** Replace a positive-total sanity check with a hand-counted result covering text, thinking with/without signatures, tool names/arguments/results, and search titles with/without snippets. Dropping a contribution now fails the test.
- **Streaming parser:** The former mixed-line-ending test only contained CRLF. It now checks both LF/CRLF boundary orderings. A short UTF-8 frame is split at every byte boundary, including inside multibyte characters and CRLF separators.
- **Tool schemas:** Add nested object required fields, descriptions, constrained scalar array items, and omission of an empty nested required list.
- **Todo:** Pin literal persisted state/priority values instead of round-tripping values generated from the same enum. Cover completed/cancelled state with label conjunction, newest-first priority ties, overdue/later-today membership, empty bucket omission, and non-open grouping.
- **Bible search:** Keep inverted-range coverage and add zero/non-numeric starts, invalid ends, and extra separators, all retaining the valid chapter fallback.
- **Bible paragraphs:** Assert the encoded discriminator and payload for every case, preserve round trips, reject missing/wrongly typed payloads, and correct the malformed-paragraph test that mistakenly decoded `BibleBook`.
- **Bible numeric arguments:** A new pure unit test reproduced a fatal `Double`-to-`Int` overflow for finite values outside the representable range. Use exact conversion to return nil for invalid numbers. Annotation and note tools share the same parser rather than maintaining duplicate trapping conversions; spy-backed tests require errors without writes for unrepresentable positions.

## Validation

Use Xcode 26.4.1 / `17E202` with Swift 6.3.1. Run each package with:

```sh
DEVELOPER_DIR='/Applications/Xcode 26.app/Contents/Developer' swift test --parallel --enable-code-coverage -Xswiftc -warnings-as-errors
```

Three isolated executions of the original Chat copy tests took 1.292, 1.280, and 1.267 seconds. The deterministic versions took 0.032, 0.031, and 0.032 seconds: median 1.280 → 0.032 seconds (97.5% less test execution time for this pair). Compilation and SwiftPM startup are excluded. The full local Chat run changed from 1.590 to 0.650 seconds in the initial comparison; concurrent machine load makes this indicative, not a promised CI reduction.

Final complete package runs passed: Core **318**, Chat **1,095**, Bible **823**, Todo **87**, totaling **2,323** reported tests versus **2,327** before. Thirteen functions were removed and nine added; existing functions were also strengthened. Most valuable changes improve what the assertions detect, rather than reducing test counts.

Own-source line coverage improved for `JSONToolSchema` (81.82% → 92.05%), `TodoFilter` (97.10% → 100%), and `BibleSearchQueryParser` (98.99% → 100%). `ContextAssembler` remains 100%. `TokenEstimator` stays 97.53% and `BibleParagraph` stays 100% despite stronger assertions: line coverage alone did not expose those weak tests. The old numeric parser also reported 100% line coverage while still trapping on untested numeric boundaries.

Ten temporary negative controls were detected: remove each copy cancellation, reverse SSE boundary selection, exclude the exact threshold, omit thinking signatures, skip the completed-state filter, reverse priority ties, change a persisted priority value, accept an extra verse separator, and encode the wrong paragraph tag. All mutations were restored. The numeric regression additionally reproduced the original fatal conversion before its fix.

Compare coverage only within each package's own production sources; applet totals printed by CI also include Core. Existing coverage floors remain unchanged. Broad macOS coverage includes unrendered SwiftUI and platform adapters, so it does not establish that the repository's stated coverage floors are met. Removed placeholder version access can lower line coverage without removing a user-facing behavior; meaningful newly exercised branches are reported in the PR.

## Deferred to the integration audit

- Bible's full translation/book/chapter database-versus-JSON parity test is the longest test in the measured Bible run. Preserve its corpus integrity checks until an integration-specific review evaluates them.
- Database migrations, repositories, reactive queries, applet live-dependency smoke tests, URLSession/Keychain/filesystem behavior, event-bus flows, and session-switching integration tests were preserved.
- Provider/reducer tests, failure paths, cancellation/ordering cases, persistence formats, and large inputs that exercise real limits were retained. Similar-looking provider fixtures are not interchangeable protocol contracts.
- Visual inventory remains **623 → 623**. No rendered UI changes or UIKit-only unit changes were made.
