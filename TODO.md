# Super — TODO

The single backlog of *what is open*. The MVP build log (M0–M12, complete 2026-05-10) is archived at [`docs/archived/IMPLEMENTATION_STATUS.md`](docs/archived/IMPLEMENTATION_STATUS.md). Each item below links back to the doc that defines it.

## How to use this file

- Items grouped by area, then ordered loosely by priority within each area.
- `P0` = blocks the current focus. `P1` = needed for v1. `P2` = nice-to-have / post-v1.
- New work that comes out of a session (subagent finding, user feedback, bug report) lands here first, then gets prioritized.

---

## Chat MVP (current focus)

### M11 — Voice input — ✅ complete (2026-05-10)
- [x] Physical-device walkthrough passed on a real iPhone. Minor bugs noted during the walkthrough are not blocking MVP; any polish lands under M12 follow-ups or post-v1 voice tweaks.

### M12 — End-to-end polish + coverage
- [ ] Lift Chat coverage to ≥ 70% threshold from current ~36% via `swift test` (or measure properly via xcodebuild + an iOS test scheme — see CI section).
- [ ] Cover the heavy 0%-coverage Settings panes (`SettingsAboutPane`, `SettingsAppearancePane`, `SettingsCompactionPane`, `SettingsDataPane`, `SettingsModelDetailPane`, `SettingsModelsPane`, `SettingsPromptPane`, `SettingsRootPane`, `SettingsThemePane`, `SettingsToolsPane`, `SettingsVerbosityPane`) — at minimum snapshot tests in light/dark/sepia.
- [ ] Cover `SidebarDrawer.swift` (currently 0%) with snapshots for closed / open-empty / open-populated / active-row / running-spinner per spec.
- [ ] Cover `MessageList` block renderers (currently 1.89%) — extract/snapshot the per-block subviews.
- [ ] Cover `KeychainClient` paths (currently 26%) — wrap a fake at the boundary so the credential-roundtrip flow can be unit-tested.
- [ ] Address M10 SHOULD findings tagged `TODO(M12)` in code (S-6 hard-coded font sizes, S-9 hard-coded margins).
- [ ] Fix wall-clock greeting drift in `ChatScreenViewModelProjectionTests` (afternoon→evening) — inject a fixed clock for all snapshot tests so we don't re-record on a time-of-day flip.
- [ ] Doc updates per the archived M12 notes: add `ToolRegistration`, `ChatSessionStore`, `ContextAssembler`, `Compactor`, `CompactionCheckpointRecord`, `.thinkingDelta`, `.compactionStarted`/`.compactionCompleted` to `docs/MOBILE_ARCHITECTURE.md` and `docs/Chat/ARCHITECTURE.md`.

---

## CI / CD (P0 for autonomous agent work)

### GitHub Actions — what's wired now
- ✅ `swift-test.yml` — runs `swift test` on Core + Chat on every PR.
- ✅ `ios-build.yml` — `xcodebuild build` + Chat snapshot/unit tests for iOS sim on every PR.
- ✅ `swiftlint.yml` — Docker-image SwiftLint runs on every PR touching Swift / config; `.swiftlint.yml` baseline allows ~15 known warnings, errors gate the merge.
- ✅ `claude-pr-review.yml` — `anthropics/claude-code-action@v1` posts an AI review on PR open/sync. Skips quietly if `CLAUDE_CODE_OAUTH_TOKEN` secret is unset.
- ✅ `secrets-scan.yml` — `gitleaks` scan on every PR + push to main + weekly cron. Pinned to gitleaks v8.30.1, fails the check on any finding.
- ✅ `.github/CODEOWNERS` — routes review request to repo owner so branch-protection "code owner review" gates work.

### CI gaps (still TODO)
- ✅ Pin the iOS-test job's simulator runtime — fixed by switching `ios-build.yml` and `swift-test.yml` to `maxim-lobanov/setup-xcode@v1 latest-stable` (gives Xcode 26.x + iOS 26.x sim) and dropping `continue-on-error: true` from `ios-test`.
- [ ] **Codecov integration** — wire `codecov-action@v4` into the swift-test + ios-build workflows. Configure thresholds (Core ≥ 80%, Chat ≥ 70%) per `AGENTS.md`. The Chat test scheme now runs in CI; coverage data is available.
- [ ] **Branch protection rules** on `main` per `docs/CI_PIPELINE.md` §7.2: require PR + 1 approval (CODEOWNERS), require status checks (`swift-test (Core)`, `swift-test (Chat)`, `build`, `ios-test`, `lint`, `review`), require linear history, no direct pushes, no force-push. Apply via `gh api` after the new checks have completed at least once on a PR so the names are registered.
- [ ] **Notify-ready workflow** per `docs/CI_PIPELINE.md` §11.2 — pings a webhook when all checks pass on a PR.
- [ ] **Server CI** — deferred until the server actually exists.
- ✅ `testflight.yml` — `workflow_dispatch` + `release/v*` tag triggers; uses App Store Connect API key (`-allowProvisioningUpdates`) for cloud-managed signing. Build numbers come from `github.run_number`. Required secrets: `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY`, `APPLE_TEAM_ID`. First successful run will register `bundle ID + cert + profile` on Apple's side.
- [ ] **Tighten SwiftLint baseline** — fix or suppress the ~15 known warnings (mostly `empty_string`, `optional_data_string_conversion`, `function_parameter_count`), then flip the `swiftlint` job to `--strict` so warnings also gate.
- [ ] **Auto-discover SPM packages in `swift-test.yml`** — today the matrix is hard-coded to `[Core, Chat]`, so adding a new package under `Packages/` requires editing the workflow and updating branch protection. Replace with a `discover` job that finds every `Packages/*/Package.swift` and emits the list as a JSON output, then have `test` consume `${{ fromJson(needs.discover.outputs.packages) }}` as its matrix. Add a `summary` job that depends on the matrix and is the **only** required check (per-package job names change as packages come and go — gating on the summary keeps protection static). Apply the same pattern to `ios-build.yml` if it ever needs to test multiple iOS schemes.
- ✅ `ios-test` added to required checks on `main` (2026-05-10) via `gh api -X POST /repos/.../branches/main/protection/required_status_checks/contexts`. Required contexts on `main` are now `test (Core)`, `test (Chat)`, `build`, `ios-test`, `lint`, `gitleaks` (bare check-run names — legacy branch protection literal-string-matches against these, not the workflow-prefixed display form).
- [ ] **Fix FakeLLMProvider parallel-test flake** — `FakeLLMProvider.swift:83` fatal error still fires intermittently on `ios-test` even after the `_waitForPendingTitleTask` + `.serialized` fix landed (PR #4). Likely leak source is one of the other suites that uses `FakeLLMProvider` — `ChatSession*Tests`, `CompactorTests`, etc. — not just `ChatScreenViewModelTests`. Now blocking merges since `ios-test` is a required check; **temporary workaround**: re-run the failed `ios-test` job once before debugging — it usually passes on retry.

---

## Server (not yet started — designed in `docs/`)

Per [`docs/SERVER_ARCHITECTURE.md`](docs/SERVER_ARCHITECTURE.md), [`docs/CLIENT_SERVER.md`](docs/CLIENT_SERVER.md), [`docs/AUTH.md`](docs/AUTH.md), [`docs/SECURITY.md`](docs/SECURITY.md). Stack: TypeScript + Hono + Drizzle + Postgres + Redis. None of this exists in the repo yet — Chat currently runs fully on-device against the user's BYOK endpoint.

- [ ] **P1** Scaffold `super-server/` with the layout from `docs/SERVER_ARCHITECTURE.md`: gateway, per-applet services, admin dashboard, Drizzle schema, Docker Compose for Postgres + Redis.
- [ ] **P1** First-run wizard at `http://localhost:3000/admin/setup` — admin account, LLM provider config, applet enablement (per `docs/DEVELOPMENT_SETUP.md` §4).
- [ ] **P1** JWT auth (refresh-token rotation, device-bound sessions) per `docs/AUTH.md`.
- [ ] **P1** LLM proxy — server holds the API key, client never does. Required by `docs/PRODUCT_VISION.md` §2.7 (privacy default) when the user opts out of local-only mode.
- [ ] **P1** `GET /api/config` for the client to discover enabled applets per `docs/DEVELOPMENT_SETUP.md` §6.
- [ ] **P2** Server CI workflow + Codecov per `docs/CI_PIPELINE.md` §5.
- [ ] **P2** Deploy pipeline (Docker build → registry → Fly.io / Railway / ECS).

## Sync engine (designed, not built)

Per [`docs/SYNC.md`](docs/SYNC.md). Custom platform-agnostic change-set protocol (not CloudKit). Each install is local-only today.

- [ ] **P1** Client-side `SyncEngine` with last-write-wins per record per `docs/SYNC.md`.
- [ ] **P1** Server `/api/sync/push` + `/api/sync/pull` endpoints + Drizzle `sync_changes` table.
- [ ] **P1** Conflict resolution for the model-config + per-applet record types defined so far.
- [ ] **P2** End-to-end encryption for synced payloads per `docs/SECURITY.md`.

---

## Other applets (designed, not built)

Per `docs/PRODUCT_VISION.md` §4 + §11 and `docs/CHAT_INTERACTIONS.md`. Every applet must implement the bi-directional contract (tool calls + chat-card renderers + record actions + deep-link targets) — see `docs/PRODUCT_VISION.md` §4 intro.

- [ ] **P1** ToDo applet (launch set per `docs/PRODUCT_VISION.md` §4.2).
- [ ] **P1** Recipes applet (§4.3).
- [ ] **P1** Bible applet (§4.4).
- [ ] **P2** Finance applet (§4.5) — needs Plaid integration.
- [ ] **P2** Calendar applet (§11) — EventKit.
- [ ] **P2** Home applet (§11) — HomeKit.
- [ ] **P2** Notifications applet (§11).

## Shell

- [x] **P1** Three-state overlay system (expanded / semi-expanded / minimized chat panel) per `docs/DESIGN.md` §4. Shipped 2026-05-13: `ChatOverlayContainer` + drag-handle snap + spring/reduce-motion + tap-backdrop-to-minimize in `App/Shell/` and `Packages/Chat/Sources/Chat/UI/ChatOverlay/`.
- [x] **P1** `AppletManager` registry + plugin contract per `docs/DESIGN.md` §6. Shipped 2026-05-13 as `MiniApplet` protocol + `AppletRegistry` in `Packages/Core/Sources/Core/Applet/`; four placeholder applets registered in `App/Shell/Placeholders/`.
- [ ] **P1** Dynamic drag-resize with composer/pill morph: continuous rubber-band tracking during drag (currently snap-on-release only); composer and minimized pill share UI elements so the transition between them animates as a single shape morph. Larger refinement, separate PR.
- [ ] **P2** macOS Catalyst / native target. iOS only today; `project.yml` has `SUPPORTS_MACCATALYST: NO`.
- [ ] **P2** iPad split-view layouts (snapshot baselines per form factor required by `AGENTS.md` §Testing).

## Cross-applet plumbing

- [ ] **P1** `SuperEventBus` (in-memory `AsyncStream` of generic events) per `docs/MOBILE_ARCHITECTURE.md`. Currently no events are published — there's only one applet.
- [ ] **P1** Shared chat-card renderer registry so any applet can render an inline card for its tool results.
- [ ] **P1** Long-press → "Add to current chat" / "Start new chat with this" menu per `docs/PRODUCT_VISION.md` §2.3.

---

## Observability (designed, not wired)

Per [`docs/OBSERVABILITY.md`](docs/OBSERVABILITY.md). No metrics, crash reporting, or analytics in the binary today.

- [ ] **P2** Crash reporting (Sentry SDK or equivalent).
- [ ] **P2** Analytics (PostHog or equivalent).
- [ ] **P2** Server-side metrics + structured logging per `docs/OBSERVABILITY.md`.

## AI tooling

Per [`docs/AI_TOOLS.md`](docs/AI_TOOLS.md).

- ✅ Wire the AI PR reviewer — `claude-pr-review.yml` runs on every PR open/sync, posts a `claude[bot]` review via `anthropics/claude-code-action@v1`. Verified end-to-end on PR #7 (Dependabot auto-merge fired with the workflow + official Claude GitHub App both present; the orphan `queued` Claude check-suite is non-required and ignored by auto-merge).
- [ ] **P2** Standardize the agent-handoff protocol — branch naming, PR template, per-agent metadata in PR body — per `docs/CI_PIPELINE.md` §6.

---

## Open design questions (need a call)

- `docs/CI_PIPELINE.md` §13 lists 8 open questions: AI reviewer model choice, blocking vs. non-blocking review, self-hosted vs. hosted runners, Fastlane vs. raw `xcodebuild`, migration strategy, agent self-merge, cross-applet integration test strategy, Xcode version pinning. Pick answers before scaling agent activity.
- `docs/PRODUCT_VISION.md` §11 has open product questions on web/Android/Kotlin Multiplatform.
