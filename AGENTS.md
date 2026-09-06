# Super — Agent Guidelines

SuperOS is the personal app; SuperBible is the public App Store target. An **applet** is a hosted app, a **module** is a Swift package, and the **shell** composes them.

## Read for the task

- Naming anything: [NAMING_CONVENTIONS.md](docs/NAMING_CONVENTIONS.md).
- Architecture or cross-applet work: [MOBILE_ARCHITECTURE.md](docs/MOBILE_ARCHITECTURE.md); shell/UI: [DESIGN.md](docs/DESIGN.md); Chat: [docs/Chat/](docs/Chat/).
- SuperBible target, its `project.yml` entries, or future Plans/Memorize/Quiz/Learn packages: [fork design](docs/superpowers/specs/2026-05-23-superbible-fork-design.md) and [overview](docs/SuperBible/OVERVIEW.md).
- Tests, snapshots, or simulator verification: [TESTING.md](docs/TESTING.md). Build setup: [DEVELOPMENT_SETUP.md](docs/DEVELOPMENT_SETUP.md). CI: [CI_PIPELINE.md](docs/CI_PIPELINE.md), with implemented behavior in [`.github/workflows/`](.github/workflows/).
- Security or diagnostics: [SECURITY.md](docs/SECURITY.md), [OBSERVABILITY.md](docs/OBSERVABILITY.md).
- Server/auth/sync work: [SERVER_ARCHITECTURE.md](docs/SERVER_ARCHITECTURE.md), [CLIENT_SERVER.md](docs/CLIENT_SERVER.md), [AUTH.md](docs/AUTH.md), [SYNC.md](docs/SYNC.md). These describe the SuperOS roadmap; `super-server/` is not implemented. SuperBible has a separate CloudKit roadmap.

## Delivery workflow

For substantive implementation tasks, unless the user directs otherwise:

1. Write a focused plan in a Markdown file: approach, risks, and validation.
2. Have a review subagent critique the plan; address actionable findings before implementing.
3. Implement the plan and complete relevant QA.
4. Have a separate review subagent review the changes; address findings and repeat affected validation.
5. Create a draft PR using the repository template and include test results.
6. Monitor CI and Codex review; fix failures and address review findings. Request a Codex pass if none starts.
7. After explicit Codex approval of the **current revision** and passing applicable CI, mark the PR ready and enable auto-merge. Verify required checks remain enforced; never bypass them. Subsequent changes require renewed review/approval. Verify the eventual merge.

Questions and trivial documentation edits do not require the full process unless requested.

## Worktree discipline

- Edit only in the session's workspace root unless the user authorizes another location. Re-root paths copied from docs or agent output; give any delegated work the same root. Confirm edits with `git status` there.
- After a PR is verified `MERGED`, **keep the worktree and local branch**. Delete only that worktree's dedicated simulator; worktree/branch cleanup requires an explicit user request.

## Architecture and persistence

- Applets import Core, never another applet. Cross-applet communication uses `SuperEventBus` with generic events/`RecordReference` and local projections, never another applet's database. App targets are the composition roots.
- Use GRDB, one `DatabaseQueue`/`.sqlite` per applet, with explicit SQL in `DatabaseMigrator`. Persisted records are structs conforming to `Codable, FetchableRecord, PersistableRecord, Sendable`.
- If displayed database rows can change outside the view, bind through GRDBQuery `@Query`. Single-owner flows or state that merges records with streaming/drafts may use imperative repository reads in an `@Observable @MainActor` view model. Never hand-roll `ValueObservation` inside a view model.
- No Combine for data flow; use `AsyncStream`/`AsyncSequence`. Use actors for shared state or `os_unfair_lock` for synchronous atomic mutation; no `DispatchQueue`/`NSLock` synchronization.
- Use protocol-typed services at applet boundaries. Inject Core's `Clock`/`IDGenerator` into testable logic; reuse `FixedClock`/`DeterministicIDGenerator` in tests.
- Throw domain `Sendable` error enums defined alongside the API. Public declarations and test suite types carry short `///` documentation directly above the declaration.

## Typography and controls

- All fonts resolve through `@Environment(\.superTypography)` and `SuperTypography` accessors. No raw `Font.system`/`Font.custom` or `.font(.system/.custom)` at call sites; [SwiftLint](.swiftlint.yml) enforces this. Use `typography.font(size:)` for arbitrary sizes. A necessary exception needs a local lint suppression with its rationale, not a weakened rule.
- **All content and chrome track the app font-scale slider.** Only the Settings monogram (`SettingsAboutPane`) and model badge (`SettingsModelsPane`) use `tracksFontScale: false`. Accessors already apply the slider; don't multiply it again. For OS Dynamic Type, brand faces use `relativeTo:`; system faces use a `@ScaledMetric` base with `font(size:)`. `SidebarDrawer` demonstrates both axes.
- Glass goes through `SuperGlass`: `superGlassButton(in:)` for tappable chrome, `superGlassSurface(in:)` for passive surfaces. No direct `.glassEffect(...)`. Remove old fill/border/shadow treatments when adopting glass; never use clear glass over text.
- Present sheets with native `.sheet`; use `NavigationStack` for sub-panes. Follow `SettingsHeader`: leading circular glass close/back button, centered title, balancing trailing spacer. Panels use the theme's `background`/`backgroundRaised`. The Chat transcript stays in its existing overlay; this sheet rule does not change its presentation.

## Testing

Follow [TESTING.md](docs/TESTING.md) for required coverage, snapshot scaffolding, async seams, and the exact CI simulator environment. Run each affected package's suite before opening a PR; UIKit snapshots require simulator tests in addition to `swift test`. App-target verification has a documented exception there.

Use [the PR template](.github/pull_request_template.md); include the new/updated tests and local results in **Test Coverage**. If a PR has no checks, inspect `gh pr view <N> --json mergeable,mergeStateStatus` for conflicts before retriggering CI.

## Integrations

- Bring Your Own Key (BYOK): users supply provider keys; store them in Keychain. Add external APIs only when essential to the applet's function.
- Observability uses Apple built-ins only. No third-party analytics, crash, advertising, attribution, or telemetry SDKs; see [OBSERVABILITY.md](docs/OBSERVABILITY.md).

## Maintaining these instructions

`AGENTS.md` is canonical; `CLAUDE.md` is a sibling symlink to it. Nested files add only local constraints. Create a nested file only when the directory has non-obvious rules worth loading, and pair it with `ln -s AGENTS.md CLAUDE.md`.

Keep these files to project-specific decisions and gotchas. Omit language tutorials, generic engineering advice, source inventories, milestone history, and rules already stated in a parent. Put detailed procedures in one linked doc with a clear read trigger.

## Pull Request Review Policy

Codex reviews report only serious, actionable findings: correctness, architecture, concurrency, persistence, security, testability, or regressions. Cite tight file/line evidence; suppress style-only narration and non-actionable summaries. Apply this root file and the nested `AGENTS.md` files for the changes in scope.
