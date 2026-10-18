# Xcode 27 migration

## Approach

- Move Apple build, package-test, snapshot, and TestFlight jobs from `macos-26` to `xcode-27`, selecting stable Xcode 27.0 (`27A266a`) explicitly.
- Update the project toolchain metadata and architecture/toolchain cache keys. Preserve iOS 26.0 deployment support and required check names.
- Apple's local download catalog identifies iOS 27.0 as simulator build `24A434`. Prepare workflows and shared simulator pins atomically for that build; log hosted runtime inventory before capture so CI confirms availability. A hosted mismatch must stop the migration until reconciled, without weakening guards. Keep iPhone 17 and XcodeGen 2.45.4 unless validation establishes an incompatibility.
- Update active setup/testing/CI documentation and guard fixtures together. Preserve historical test reports.
- Compare all 601 visual captures on the new environment, inspect renderer differences, explicitly record intentional changes locally, and rerun comparisons. Preserve inventory and comparison tolerances.

## Risks and prerequisites

- GitHub labels `xcode-27` as a preview runner; it changes the host OS and architecture as well as the compiler and SDK.
- Swift 6.4, new SDK diagnostics, and SwiftUI rendering can require compatibility fixes and reviewed baseline changes.
- The local Mac now runs macOS 27.0.1. Super.xcodeproj opened successfully in Xcode 27.0 (`27A266a`). iOS 27.0 (`24A434`) is installed; the worktree owns iPhone 17 simulator `7A325181-82B0-4244-B9DE-50AFF764DBCC`. XcodeGen 2.45.4 is available in the ignored workspace tools directory with its release checksum verified.
- The runner README lists iOS 27.0 but does not establish its concrete simulator build. Hosted validation of `24A434` remains required before completion.

## Validation and delivery

1. Review this plan with a review subagent before implementation. Completed; incorporated the requirement to discover the runtime before atomically changing workflow and simulator pins.
2. Validate workflow syntax, capture/preview guards, worktree lifecycle tests, hook tests, and unchanged inventory.
3. Run each Swift package suite with warnings as errors, build Super and SuperBible, and compare the full visual inventory using the registered worktree simulator on the pinned environment.
4. Obtain a separate change review, open a draft PR with exact results and any unavailable checks, and inspect hosted compiler/runtime evidence.
5. Resolve failures and review findings. Require current-revision Codex approval and all applicable CI checks before making the PR ready, enabling auto-merge, and verifying the merge.

## Sources

- [GitHub Xcode 27 runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
- [GitHub runner announcement](https://github.com/actions/runner-images/issues/14404)
- [Apple system requirements](https://developer.apple.com/xcode/system-requirements/)

## Preparation results

- Moving the book-row scroll target onto its header restores the current-book position in the mid-canon and embedded-picker fixtures; late-chapter anchoring is preserved. The original one-shot `onAppear` policy remains.
- Disabling automatic content-offset adjustment through SwiftUI's transaction policy restores Chat response stability. All 12 existing UIKit scroll tests pass unchanged, including send focus, streaming, handoff, manual scrolling, and resize cases.

- Super and SuperBible simulator builds passed with signing disabled.
- Package suites passed with warnings as errors: Core 339, Bible 953, Chat 1,144, Todo 87 (2,523 total).
- Simulator/helper tests: 35 passed, including six Cryptex disk compatibility tests. Capture guards: 49 passed. Native preview guards: 38 passed. Hook fixtures and workflow YAML parsing passed.
- Swift 6.4 required the migration test to return sendable database values. The seeding test now checks the framework's live context size used by production.
- Both capture drivers accept only verified superseded Cryptex mount records for the same asset and retain raw disk evidence. Conflicting builds/assets and multiple Ready mounts remain failures.
- Both visual dependency lockfiles now contain swift-issue-reporting 2.1.2, required by their existing swift-custom-dump pin. All other dependency pins are unchanged.
- Package capture generation now uses an ignored project under `.build`, with rebased package schemes, so it preserves signing edits in the open project. A regression test verifies isolation.
- All 601 captures were visually reviewed before accepting baseline updates; 582 PNG files changed. Differences include text/symbol rasterization, native control rendering, and small reader inset/reflow changes. One size-to-fit reference pill grows from 167×139 to 167×141 pixels, reflected in its exact inventory entry. Capture count and comparison tolerances are unchanged.
- Full visual comparison and hosted CI remain completion gates. Chat's 233 image comparisons pass after the response-stability fix; the complete pipeline will also verify the updated size inventory and final book-header target.
- Concurrent local signing edits in the generated project are outside the migration and must not be included in its commit.
