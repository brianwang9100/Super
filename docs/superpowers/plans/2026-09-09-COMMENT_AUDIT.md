# Comment Audit Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` to execute the reviewed tasks. Root `AGENTS.md` requires a plan-review subagent and a separate implementation-review subagent. Execution was authorized after plan review. All source batches, final integration, and local validation are complete; PR delivery is in progress.

**Goal:** Reduce unnecessary source-reading tokens by removing redundant comments and shortening useful explanations, while preserving information needed to use and maintain the code correctly.

**Approach:** Replace the blanket documentation requirement, calibrate the policy on representative files, then manually review every tracked source/configuration file in batches. Keep behavior and source structure stable so each diff is easy to verify. Counts measure the result; they are not deletion targets.

**Tech stack:** Swift/SwiftUI, Swift Testing, Python, shell, JavaScript/JSX, YAML, SwiftLint, GitHub Actions.

**Design basis:** The user's request to use comments sparingly for clarifications, especially hacky code. This plan includes the proposed policy and audit design; no separate spec is needed for this bounded maintenance task.

## Findings from the planning audit

Baseline: `c6a49ba3`, September 9, 2026. The working tree was clean before this plan. These are inventory counts plus representative file inspection, not a completed classification of every comment.

| Swift area | Files | All lines | Full-line comment candidates |
|---|---:|---:|---:|
| Chat | 284 | 63,035 | 13,238 |
| Bible | 271 | 40,691 | 7,453 |
| Core | 122 | 12,857 | 3,271 |
| Todo | 54 | 5,233 | 731 |
| Shared app code | 7 | 2,052 | 913 |
| SuperOS target | 5 | 625 | 220 |
| SuperBible target | 4 | 624 | 225 |
| Scripts | 9 | 798 | 106 |
| **Total** | **756** | **125,915** | **26,157 (20.8%)** |

Method: `git ls-files`, then count Swift lines matching `^\s*///` and `^\s*//(?!/)`. There are 17,832 documentation lines and 8,325 ordinary comment lines; the latter include 414 `MARK:` lines and 10 tool directives. This heuristic excludes trailing/block comments and can include comment-like lines inside strings. It is a prioritization baseline, not a tokenizer measurement or an estimate of how much is removable. Swift files outside `Tests` contain 19,395 candidates; test files contain 6,762.

Also inventory all 27 tracked Python files, four shell files, two MJS files, four JSX files, 11 YML files, and the YAML, TOML, and xcconfig files. Python docstrings need separate treatment because they are string literals. Audit hidden tracked tooling too; a search that respects ignore rules alone can miss it.

The docstring distinction is material here: several visual-testing CLIs and `Scripts/worktree_simulator.py` use `__doc__` as help text, and `Packages/Bible/Scripts/generate_bible_text_sqlite.py` prints it. Leave these strings intact. The remaining inventory must also include maintained configuration templates such as `Config/Local.xcconfig.example` and `.codex/rules/default.rules`, regardless of filename extension.

The root rule currently says: “Public declarations and test suite types carry short `///` documentation directly above the declaration.” None of the seven nested `AGENTS.md` files repeats this requirement, and the inspected SwiftLint configuration does not enforce documentation coverage. `CLAUDE.md` is a symlink to `AGENTS.md`. Historical descriptions of the old rule occur in `docs/archived/IMPLEMENTATION_STATUS.md`; leave historical records intact.

Representative findings:

| File | Decision to calibrate against |
|---|---|
| `Packages/Core/Tests/CoreTests/Ambient/ClockTests.swift` | Delete “Tests for `SystemClock` and the deterministic `FixedClock`.” The suite and test names already say this. |
| `Packages/Core/Sources/Core/Ambient/Clock.swift` | Remove `now()`'s return-type narration and repeated root testing policy. Retain the reason the mutable test clock uses synchronous locking. |
| `App/Shell/AppShellLaunchBehavior.swift` | 28 comment lines in 35 total. Keep cold-launch-only semantics and the unsupported `.semiExpanded` constraint; drop speculative implementation advice and repeated target defaults. |
| `Packages/Core/Sources/Core/Events/SuperEvent.swift` | Keep payload correlation, routing, and lifecycle contracts. Shorten consumer histories and repeated implementation walkthroughs. High density alone does not justify deletion. |
| `App/Shell/AppShell.swift` | 676 candidates. Shorten repeated bootstrap descriptions; preserve why queued navigation must see fresh environment values and why focus is shared. |
| `Packages/Chat/Sources/Chat/UI/ChatScreen.swift` | Remove the obsolete M1/M3 gesture narrative after verifying the current gesture wiring. Keep progress units and callback contracts that callers need. |
| `Packages/Chat/Sources/Chat/UI/ChatOverlay/OverlayContentDragGesture.swift` | Preserve the gesture-start latch and edge/handoff rules; shorten repeated examples only when those rules remain explicit. |
| `Packages/Chat/Sources/Chat/Orchestration/ContextAssembler.swift` | Preserve prompt ordering, checkpoint boundaries, and cache rationale. These are not recoverable from a signature. |
| `Packages/Chat/Sources/Chat/Models/ToolCallRecord.swift` | Preserve provider ID, persisted encoding, and correlation semantics. Remove routine acronym expansions and repeated field descriptions. |
| `.github/workflows/ios-build.yml`, `.github/workflows/testflight.yml` | Preserve required-check scheduling and workflow-expression pitfalls; shorten repeated history and descriptions of obvious steps. |

## Proposed AGENTS.md change

Keep the domain-error sentence in “Architecture and persistence” and remove its appended blanket documentation sentence. Add this short section before “Typography and controls”:

```markdown
## Comments

- Let names, types, and control flow explain the code. Comment sparingly to clarify non-obvious contracts, invariants, rationale, or workarounds; keep the explanation close to the code and as short as clarity allows.
- Public declarations and test suites do not require comments by default. Use `///` for caller-facing information the signature cannot express, such as units, side effects, ordering, or cancellation. Do not restate names, signatures, or obvious steps.
- For workarounds, explain the constraint and why the straightforward approach fails; include an issue or removal condition when known. Preserve legal notices and tool directives with their necessary rationale.
- Remove stale history, milestone notes, tutorials, and duplicated explanations. Keep `MARK:` sections only when they materially aid navigation. When changing code, update or remove comments it invalidates.
```

This is the recommended approach. A policy-only change would leave the existing reading cost in place. Automated bulk deletion would lose contracts and workaround context. Use human/agent judgment on each comment; do not add a comment-ratio linter or a required reduction percentage.

## Scope and constraints

- Audit maintained production code, tests/helpers/previews, package manifests, scripts, workflows/actions, and source configuration. Inspect tracked hooks/rules and design JSX as part of the inventory; record areas with no removable comments as reviewed.
- Exclude dependency/build output, vendored code/patches, generated artifacts, image/text/database fixtures, bundled prompts, localization/product copy, and historical design documents. Keep legal and attribution text. If generated source is encountered, review its generator rather than hand-editing its output.
- Edit comments and their adjacent blank space only. Defer renames, extraction, behavior changes, new dependencies, test deletions, and unrelated documentation rewrites. Record any code whose unclear structure warrants a later refactor.
- Preserve SwiftPM tools-version comments, shebangs, encoding headers, linter/formatter/code-generation directives, and their attachment/scope. In particular, keep `swiftlint:disable:next` on the intended statement and retain its rationale.
- Preserve comment-looking text in raw/multiline strings, regular expressions, SQL, prompts, and test inputs. YAML `run: |` content is a shell program, and its `#` lines are scalar contents to YAML; review at both layers. Protect workflow expressions and heredoc boundaries.
- Python docstrings can affect `__doc__`, help output, and introspection. Inventory them, but keep them unchanged in this comment-only pass; propose any useful trimming separately with consumer checks.
- Review stale TODO/FIXME notes individually. Keep unresolved constraints and actionable follow-ups; remove only those confirmed obsolete. Do not erase a still-valid warning merely because its issue reference is old.
- Prefer one authoritative explanation at the API or invariant owner. Keep a short local warning/reference where removing it would make a caller's unusual code unsafe to understand. Do not copy deleted prose into a new documentation dump.
- Update source-comment references invalidated by the cleanup. For example, `ChatSessionTests.swift` refers to “ChatSession docstring lines 8-12”; point to the named contract instead of preserving a brittle line reference.
- Use `/Users/bwang/.codex/worktrees/fb27/Super` as the execution workspace; rebase all example paths to that root. Preserve the `CLAUDE.md` symlink.

## Tasks

### 1. Establish policy and audit inventory

**Files:** Modify `AGENTS.md`; create `docs/COMMENT_AUDIT.md`; use ignored `.build/comment-audit/` for per-file inventory and temporary measurement tools.

- [x] Obtain an independent plan critique and address actionable findings before implementation. Counts were independently reproduced; project-generation and embedded-script validation contradictions were corrected.
- [x] Refresh the baseline revision and tracked-file inventory with `git ls-files`. Classify files as maintained code/configuration or explicitly excluded; use counts to order review, never to skip low-density files.
- [x] Apply the exact policy above. Search active root/nested instructions and lint/build configuration for conflicting requirements; amend only live contradictions. Check that `CLAUDE.md` still resolves to `AGENTS.md`.
- [x] Record each in-scope path as pending, then later as changed or reviewed/retained. Keep the detailed checklist ignored; put baseline revision, scope, method, representative decisions, and aggregate completion counts in the concise tracked audit report.
- [x] Run `git diff --check` and verify changed Markdown links. Commit the policy/report scaffold as the first reviewable change.

### 2. Calibrate on representative files

**Files:** The first four Swift files in the representative table: `ClockTests.swift`, `Clock.swift`, `AppShellLaunchBehavior.swift`, and `SuperEvent.swift`.

- [x] Apply the policy to these four files. A suitable replacement for the launch-type introduction is: `/// Applied only at cold launch; foreground returns preserve the current shell state.` Keep the unsupported initial state documented next to `initialChatState`.
- [x] Compare each removed explanation against the signature, implementation, and relevant callers/tests. Retain useful API information at its owner and shorten lengthy rationale without losing preconditions, failure modes, or ordering.
- [x] Inspect the diff for lost meaning and unintended edits. Record a few before/after examples in `docs/COMMENT_AUDIT.md` so later batches follow the same standard.
- [x] Complete the applicable validation below. Use these examples to calibrate the remaining work without requiring a separate user approval for every batch once execution is authorized.

### 3. Complete the Swift audit in reviewable batches

**Files:** All remaining tracked Swift files under `Packages/{Core,Todo,Chat,Bible}`, `App`, `App-SuperOS`, `App-SuperBible`, and `Scripts`.

- [x] Finish Core and Todo, including tests, helpers, previews, and manifests. Delete repeated test-suite summaries and obvious member/initializer narration. Preserve public contracts and persistence invariants.
- [x] Review Chat, beginning with `ChatScreenViewModel.swift`, `ChatSession.swift`, `SettingsModelDetailPane.swift`, `ChatScreen.swift`, `OverlayContentDragGesture.swift`, and `ContextAssembler.swift`; then cover every remaining path. Pay particular attention to streaming completion, cancellation, task-draining seams, provider quirks, and prompt composition.
- [x] Review Bible, beginning with `BibleScreenViewModel.swift`, `BulkAnnotationRunner+Live.swift`, `BibleChapterReader.swift`, `BibleParagraphBlock.swift`, and `BibleApplet.swift`; then cover every remaining path. Preserve SQLite ownership, annotation/narration ordering, selection, and accessibility constraints.
- [x] Finish shared shell, both target bootstraps, and Swift scripts. Read the linked shell/target architecture documents before editing those areas. Remove outdated roadmap narration after checking actual behavior; keep platform and first-frame workarounds.
- [x] For each batch, include trailing comments, block comments, `MARK:` headings, and test comments in the manual review. Mark every inventoried path changed or reviewed/retained; validate and commit each coherent batch.

### 4. Audit tooling and finish measurement

**Files:** Tracked scripts including `Packages/Bible/Scripts`, `.github/workflows`, `.github/actions`, tracked hook/rule files, design JSX, `project.yml`, `.swiftlint.yml`, and `Config/Base.xcconfig`; update `docs/COMMENT_AUDIT.md`.

- [x] Review explanatory comments in each remaining maintained source/configuration file. Remove repeated command narration and duplicated configuration explanations; retain reproducibility, parser, release, environment, and operational pitfalls. Keep runtime strings/docstrings and functional directives unchanged.
- [x] Validate edited languages/configuration as described below. A build/capture tool parsing source text may depend on layout even when the compiler ignores it; include the existing tooling guard suites when relevant.
- [x] Repeat the baseline counts on the identical original file set and method. Report before/after comment lines and UTF-8 bytes by area, alongside reviewed/changed/retained file counts. Do not include new plan/report prose in source savings.
- [x] If a tokenizer is already available, measure full-file before/after tokens on that same set and name the tokenizer. Otherwise report bytes and lines only; do not convert characters to an asserted token-saving percentage or install a dependency just for this report.
- [x] Reconcile every inventory entry and document exclusions/deferred issues. Completion means all in-scope files reviewed, with no deletion quota and no unsupported token or runtime claims.

Integration note: main advanced to `ffbc76d6`. Preserve its feature changes and updated fixtures; the final identical before/after inventory is 836 files (779 Swift). All 28 added/moved paths and 33 files with restored or new comments were re-audited. The final report uses this baseline; original counts above remain the planning record.

### 5. Review and deliver

**Files:** Final source/comment diff and `docs/COMMENT_AUDIT.md`; PR uses `.github/pull_request_template.md`.

- [x] Have a separate review subagent inspect the final changes for lost contracts, misleading rewrites, changed directives/string contents, and incomplete audit coverage. Address findings and repeat affected validation.
- [ ] Open a draft PR with the policy rationale, measured reductions, audit coverage, preserved high-value examples, and actual validation results. State that test declarations/assertions and snapshot inventory are unchanged; expected image-count delta is zero because rendering is unchanged.
- [ ] Follow root delivery policy: monitor CI and Codex review together every ten minutes, remain quiet on unchanged status, and fix failures/findings. After explicit approval of the current revision and passing applicable checks, mark ready, enable auto-merge with required checks enforced, and verify the merge. Disable auto-merge before any further push and renew approval/checks for that revision.

## Validation

**Planning validation (completed):** Markdown path checks, `git diff --check`, and independent plan review. Implementation validation is recorded in [the audit report](../../COMMENT_AUDIT.md).

**For implementation:** No new behavior tests or permanent audit infrastructure are needed. Run existing checks appropriate to the touched files:

1. Inspect every diff and compare non-comment source. A temporary SwiftSyntax/SwiftParser comparison can ignore comment trivia while comparing token kind/text and syntax structure, rejecting parse errors. Both modules are present in the installed Xcode host libraries. Use it as supporting evidence, not a substitute for directive/attachment review, compiler checks, or tests. Do not use regex stripping as a behavior-equivalence proof. Preserve line-sensitive constructs such as `#line`/`#sourceLocation` and check consumers of source locations before shifting nearby lines.
2. Run `swiftlint lint --quiet` with the existing configuration and `git diff --check`. Compare baseline/new diagnostics if the checkout has unrelated failures; do not disable rules to accommodate the cleanup.
3. Run each affected package's suite from its own root, matching CI:

   ```sh
   DEVELOPER_DIR='/Applications/Xcode 26.app/Contents/Developer' swift test --parallel --enable-code-coverage -Xswiftc -warnings-as-errors
   ```

4. For shell/target changes, follow `docs/TESTING.md` app-target verification. Generate the project with `xcodegen generate`, obtain the worktree simulator with `python3 Scripts/worktree_simulator.py ensure`, and use that UUID for both `Super` and `SuperBible` builds. For comments-only UI changes, run relevant existing simulator coverage under the pinned environment; preserve all baselines and test/suite attributes. CI already runs the full snapshot inventory. No new captures or recording are warranted by this change.
5. For Python comment edits, compare `ast.dump(ast.parse(source), include_attributes=False)` before/after; unchanged docstrings remain part of the AST. Run existing affected script suites. Available commands include:

   ```sh
   python3 -B -m unittest discover -s Scripts/tests -v
   python3 -B -m unittest discover -s Scripts/VisualTesting -p 'test_*.py'
   python3 -B -m unittest discover -s Scripts/PreviewPilot -p 'test_*.py'
   bash .codex/hooks/tests/test-hooks.sh
   ```

6. For workflow edits, run `actionlint` if installed and review parsed configuration values. A YAML `run: |` scalar may differ only in shell comments/adjacent whitespace; compare the embedded program separately and preserve executable content and workflow expressions. Other configuration values must stay identical. For shell edits, run the matching shell's syntax check and existing tests. For JSX/MJS, use an existing compatible parser/build check; plain Node syntax checking is insufficient for JSX. If tooling is unavailable, report the missing check rather than invent a successful result. Never run shipping, signing, upload, or resource/data/asset generators merely to validate comments; the local Xcode project generation required in step 4 is allowed.
7. Finish with `git status --short` in this workspace. Confirm no changed executable tokens, test assertions, resource strings, tracked generated artifacts, baseline images, or operational configuration values. Embedded-program scalars may contain only the comment/whitespace differences reviewed in step 6. Keep temporary inventories/checkers ignored.

## Risks and completion criteria

The main risk is deleting knowledge the code cannot express, especially concurrency, persisted formats, and platform workarounds. Semantic review of every removal is the primary defense; a large line reduction alone is not success. Functional comments, embedded programs, and source-layout-sensitive tooling need additional checks even when ordinary comments have no runtime effect.

The work is complete when the active guidance no longer demands boilerplate, every in-scope file has a review disposition, retained comments explain necessary information, behavior/fixtures/directives remain intact, reductions are measured honestly, relevant checks pass, and the reviewed PR is merged.
