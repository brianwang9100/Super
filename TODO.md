# Super — TODO

The single backlog. [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) is *what is done now*; this file is *what is open*. Each item links back to the doc that defines it.

## How to use this file

- Items grouped by area, then ordered loosely by priority within each area.
- `P0` = blocks the next milestone. `P1` = needed for v1. `P2` = nice-to-have / post-v1.
- When a milestone is in flight, the item moves to [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) and gets crossed off here.
- New work that comes out of a session (subagent finding, user feedback, bug report) lands here first, then gets folded into a milestone when prioritized.

---

## Chat MVP (current focus)

### M11 — Voice input — physical-device verification (P0)
- [ ] Walk through `docs/superpowers/specs/2026-05-03-m11-voice-input-design.md` §10 steps 1–8 on a real iPhone.
- [ ] Flip M11 to `[x] done` in `IMPLEMENTATION_STATUS.md` (table row + section).
- [ ] Commit + push as a separate `M11: physical-device verification complete` commit.
- **Why blocked**: `SFSpeechRecognizer` cannot run on iOS 17+ simulators (Apple's documented position; we hit `kLSRErrorDomain #300` immediately). Sim catches every other path; only the real recording → partial → final → composer-commit flow needs hardware.

### M12 — End-to-end polish + coverage
- [ ] Lift Chat coverage to ≥ 70% threshold from current ~36% via `swift test` (or measure properly via xcodebuild + an iOS test scheme — see CI section).
- [ ] Cover the heavy 0%-coverage Settings panes (`SettingsAboutPane`, `SettingsAppearancePane`, `SettingsCompactionPane`, `SettingsDataPane`, `SettingsModelDetailPane`, `SettingsModelsPane`, `SettingsPromptPane`, `SettingsRootPane`, `SettingsThemePane`, `SettingsToolsPane`, `SettingsVerbosityPane`) — at minimum snapshot tests in light/dark/sepia.
- [ ] Cover `SidebarDrawer.swift` (currently 0%) with snapshots for closed / open-empty / open-populated / active-row / running-spinner per spec.
- [ ] Cover `MessageListView` block renderers (currently 1.89%) — extract/snapshot the per-block subviews.
- [ ] Cover `KeychainClient` paths (currently 26%) — wrap a fake at the boundary so the credential-roundtrip flow can be unit-tested.
- [ ] Address M10 SHOULD findings tagged `TODO(M12)` in code (S-6 hard-coded font sizes, S-9 hard-coded margins).
- [ ] Fix wall-clock greeting drift in `ChatScreenViewModelProjectionTests` (afternoon→evening) — inject a fixed clock for all snapshot tests so we don't re-record on a time-of-day flip.
- [ ] Doc updates per IMPLEMENTATION_STATUS.md M12 notes: add `ToolRegistration`, `ChatSessionStore`, `ContextAssembler`, `Compactor`, `CompactionCheckpointRecord`, `.thinkingDelta`, `.compactionStarted`/`.compactionCompleted` to `docs/MOBILE_ARCHITECTURE.md` and `docs/Chat/ARCHITECTURE.md`.

---

## CI / CD (P0 for autonomous agent work)

### GitHub Actions — what's wired now
- ✅ `client-swift-test.yml` — runs `swift test` on Core + Chat on every PR.
- ✅ `client-ios-build.yml` — `xcodebuild build` for iOS sim on every PR.

### CI gaps (still TODO)
- [ ] **Pin the iOS-test job's simulator runtime.** The `ios-test` job in `ios-build.yml` is `continue-on-error: true` because snapshot baselines are recorded against iPhone 17 + iOS 26.3 locally and macos-15 runners may carry a different default. Discover what sims the runner has, pick a stable one, pin it via `-destination`, then drop `continue-on-error`.
- [ ] **Codecov integration** — wire `codecov-action@v4` into the swift-test + ios-build workflows. Configure thresholds (Core ≥ 80%, Chat ≥ 70%) per `AGENTS.md`. The Chat test scheme now runs in CI; coverage data is available.
- [ ] **SwiftLint job** — add `.swiftlint.yml` then a workflow step. CI_PIPELINE.md §4.1 references `swiftlint --strict` but no config exists yet.
- [ ] **Branch protection rules** on `main` per `docs/CI_PIPELINE.md` §7.2: require PR + 1 approval, require status checks, require linear history, no direct pushes.
- [ ] **AI reviewer workflow** (`.github/workflows/ai-review.yml`) per `docs/CI_PIPELINE.md` §6.3 — an Anthropic-API-driven reviewer that posts inline PR comments. Requires `ANTHROPIC_API_KEY` secret.
- [ ] **Notify-ready workflow** per `docs/CI_PIPELINE.md` §11.2 — pings a webhook when all checks pass on a PR.
- [ ] **Server CI** — deferred until the server actually exists.
- [ ] **TestFlight deploy workflow** per `docs/CI_PIPELINE.md` §9.2 — needs Apple Developer account, signing certs, and provisioning profiles in GH Secrets.

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

- [ ] **P1** Three-state overlay system (expanded / semi-expanded / minimized chat panel) per `docs/DESIGN.md` §4. Today the shell only shows the full Chat surface.
- [ ] **P1** `AppletManager` registry + plugin contract per `docs/DESIGN.md` §6.
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

- [ ] **P1** Wire the AI PR reviewer (see CI section above).
- [ ] **P2** Standardize the agent-handoff protocol — branch naming, PR template, per-agent metadata in PR body — per `docs/CI_PIPELINE.md` §6.

---

## Open design questions (need a call)

- `docs/CI_PIPELINE.md` §13 lists 8 open questions: AI reviewer model choice, blocking vs. non-blocking review, self-hosted vs. hosted runners, Fastlane vs. raw `xcodebuild`, migration strategy, agent self-merge, cross-applet integration test strategy, Xcode version pinning. Pick answers before scaling agent activity.
- `docs/PRODUCT_VISION.md` §11 has open product questions on web/Android/Kotlin Multiplatform.
- License (this README + the repo currently say TBD).
