# Unit Test Audit Implementation Plan

**Goal:** Reduce unnecessary unit-test work and close meaningful behavioral coverage gaps without changing integration or visual coverage.

**Approach:** Inventory all four package suites, inspect completed CI timing and coverage data, and compare candidate tests with the implementation and retained assertions. Remove only demonstrably redundant checks of the same contract, replace unnecessary heavyweight unit fixtures where useful, and add focused tests for uncovered branches. Keep runtime claims tied to measured execution, separate from compilation and runner queue time.

**Scope:** Core, Chat, Bible, and Todo unit tests. Database, filesystem, network-stack, event-bus integration tests and visual fixtures are preserved for later audits. Existing mixed package runs remain the validation command; this task does not weaken CI checks or coverage floors.

**Risks:** Similar-looking inputs may cover different regressions; parameterization reduces source duplication but does not itself reduce executed cases; macOS coverage excludes iOS-only code; concurrent timings vary; a passing added test needs an intentional negative control to establish sensitivity when practical.

## Tasks

- [x] Inventory test declarations and suite categories; inspect all unit-test areas and identify expensive fixtures, duplicate contracts, and branch gaps. Record evidence and deferred integration findings in `docs/UNIT_TEST_AUDIT.md`.
- [x] Ask a review subagent to critique the audit approach and candidate-selection rules before implementation; incorporate actionable findings. Classify by actual dependencies, including integration tests in model/applet folders. Edited UIKit-only logic requires simulator verification; the selected changes currently run on macOS.
- [x] Run baseline package suites with CI's coverage and warnings flags using Xcode 26.4.1. Capture logs, source coverage, and execution timings outside tracked files.
- [x] For each proposed deletion, record the retained test that covers the same behavior. Prefer preserving boundary, failure, cancellation, ordering, parsing, and persisted-format compatibility checks. Consolidate only when the comparison proves redundancy.
- [x] Add focused missing unit coverage using existing deterministic fixtures, and verify useful negative controls without retaining production changes.
- [x] Run every affected package's full suite and compare coverage and repeatable execution timing with baseline. Report test-count changes separately from performance evidence. No image capture inventory change is expected.
- [x] Have a separate review subagent inspect the final changes for lost coverage, misleading tests, concurrency mistakes, and unsupported claims. Address findings and rerun affected validation.
- [ ] Create a draft PR using the repository template. Monitor CI and Codex review every ten minutes; after current-revision Codex approval and passing required checks, mark ready, enable auto-merge, and verify merge.

## Validation

From each affected `Packages/<Package>` directory:

```sh
DEVELOPER_DIR='/Applications/Xcode 26.app/Contents/Developer' swift test --parallel --enable-code-coverage -Xswiftc -warnings-as-errors
```

Use the generated package test executable and `default.profdata` with `xcrun llvm-cov export/report` to compare production-source coverage. Preserve each baseline artifact before rerunning. Final checks include `git diff --check`, scoped lint where available, and a clean review of `git status` in this workspace.

## Reviewed implementation selections

- Core: remove the unused package-version smoke test and duplicate adapter/equality checks; preserve persisted JSON contracts. Improve copy-controller tests so they drain their tasks and observe cancellation.
- Chat: inject the copy-confirmation sleep using the existing closure-based timer convention, preserving the 1.2-second default. Replace real-time waits with independently gated sleeps and explicitly assert the older task was cancelled. Remove implied role/enum checks; replace the 400,000-character threshold fixture with exact numerical boundaries. Assert exact token accounting for every content-block case.
- Todo: replace self-round-trip enum checks with literal persisted values. Add mixed-state filtering, equal-priority ordering, overdue/group membership, omitted empty groups, and ungrouped non-open coverage.
- Bible: remove the redundant heading-only coalescing case and redundant palette counts. Add malformed verse-range fallback cases and exercise every paragraph encoding case; correct the malformed-paragraph test that currently decodes the wrong type.
- All image and integration fixtures remain unchanged. Baseline CI shows compilation dominates; distinguish a measurable unit-runtime reduction from any unproven compilation gain.

## Evidence-driven amendments

Plan reviewer approved hashing Swift-test cache inputs after CI demonstrated exact fixed-key hits prevented saving rebuilt outputs. Include manifests, package Sources/Tests/resources, Core sources, and workflow; retain architecture/toolchain/package restore boundaries. Treat runtime savings as unproven until later CI confirms them.

The numeric argument unit test reproduced a fatal conversion for finite out-of-range doubles. Reviewer approved `Int(exactly:)` and identified the same conversion in annotation/note tools. Route those callers through the shared helper; their existing in-memory spies support regressions without integration changes. Validate integer boundaries, nonfinite/fractional/missing/wrong-type input and rejection without writes. This supersedes the initial assumption that only timing injection would change production code.

Final independent review found no actionable issues. Complete local suites pass (Core 318, Chat 1095, Bible 823, Todo 87). Ten temporary mutations were detected and restored; numeric overflow was reproduced in three isolated pre-fix runs. Actionlint, diff checks, and scoped SwiftLint in CI mode pass.
