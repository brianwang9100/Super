# Super — TODO

The single backlog of *what is open*. The MVP build log (M0–M12, complete 2026-05-10, includes voice input) is archived at [`docs/archived/IMPLEMENTATION_STATUS.md`](docs/archived/IMPLEMENTATION_STATUS.md). Items link to the doc that defines them.

## How to use this file

- Grouped by area, ordered loosely by priority within each.
- `P0` blocks the current focus · `P1` needed for v1 · `P2` nice-to-have.
- New work lands here first, then gets prioritized.

---

## SuperBible (App Store target)

Free, BYOK, open-source, local-first AI Bible app; sibling target to SuperOS sharing `Core` + `Chat` + `Bible`. Design: [`docs/superpowers/specs/2026-05-23-superbible-fork-design.md`](docs/superpowers/specs/2026-05-23-superbible-fork-design.md) · intro [`docs/SuperBible/OVERVIEW.md`](docs/SuperBible/OVERVIEW.md).

### SB-M0 — Target wired up ✅ (one item deferred)
- [ ] **P1** `paths-ignore` for docs-only PRs in `ios-build.yml` — *deferred:* conflicts with the required-check pattern (path-filtered checks never report on skipped PRs). Needs a design pass.

### SB-M1 — Composition root + applet registration ✅ (deferrals below)
- [ ] **P1** Settings → About row → GitHub Sponsors URL — *deferred to SB-M4* with the rest of App Store polish.

### SB-M1 follow-ups (deferred)
- [ ] **P2** App-target XCTest bundle: `AppShell` + `SuperBibleContentView` snapshots (loading/ready/failed × light/dark/Dynamic Type XXL), including both `AppShellLaunchBehavior` cases (`.minimized` and `.standard`/`.expanded`) — the gap PR #104 review flagged.
- [ ] **P3** Protocol-based bootstrap → `AppShellDependencies` adapter — only if a third target ships.

### SB-M2 — Plans applet core (no `Packages/Plans` yet)
- [ ] **P1** Brainstorm → spec → plan for the Plans applet.
- [ ] **P1** `Packages/Plans/`: GRDB schema (`ReadingPlan`, `PlanDay`, `PlanProgress`, `PlanStreak`) + GRDBQuery reactive bindings.
- [ ] **P1** Chat tools: `plans.list`, `plans.start`, `plans.today`, `plans.markRead`, `plans.streak`.
- [ ] **P1** Chat-card renderers: today's reading, progress, streak, completion.
- [ ] **P1** Long-press plan-day actions (mark read/unread, open in Bible, add to chat).
- [ ] **P1** Deep link `super://plans/<planId>/<day>`.
- [ ] **P1** Snapshot tests ship with the views.
- [ ] **P1** Add `Packages/Plans/` to the `SuperBible` target + an `.xcscheme` for iOS-runtime snapshot tests.

### SB-M3 — Plans content + onboarding
- [ ] **P1** Bundled plans (F260, M'Cheyne, Bible in a Year, Bible in 90 Days).
- [ ] **P1** Onboarding: pick a plan, set notification time.
- [ ] **P1** Local daily reading reminder (default 8am).
- [ ] **P1** Reading-streak surfacing in Plans home + chat cards.

### SB-M4 — App Store polish
- [ ] **P1** Final app icon + accent color.
- [ ] **P1** App Store Connect listing (name, screenshots iPhone 17, preview video, description, keywords, support URL).
- [ ] **P1** App Privacy nutrition label (no third-party SDKs).
- [ ] **P1** Wire Settings → About → Privacy to render `App-SuperBible/PRIVACY.md` in-app. *(PRIVACY.md drafted 2026-05-23; revise if policy changes.)*
- [ ] **P1** Confirm donation link: resolve GitHub Sponsors URL, replace placeholder.
- [ ] **P1** TestFlight beta cycle (sim + real device).
- [ ] **P1** Parameterize `testflight.yml` on scheme + per-target provisioning profile (today hard-codes `-scheme Super` / `com.brianwang.Super`).
- [ ] **P2** Add `default-data-protection = NSFileProtectionComplete` entitlement to both targets (upgrades the SQLite WAL/SHM protection class app-wide).

### SB-M5 — App Store ship
- [ ] **P1** Crash-free-sessions check (>99.5% on TestFlight) pre-submission.
- [ ] **P1** App Store review submission.
- [ ] **P1** Release notes + Sponsors page update.

### Post-launch (SB-M6+)
- [ ] **P2** Memorize applet (spaced-repetition) — own spec.
- [ ] **P2** Quiz applet (AI-generated quizzes) — own spec.
- [ ] **P2** Learn applet (guided theology paths) — own spec.
- [ ] **P3** SuperBible-specific theme palette (inherits SuperOS palette today).
- [ ] **P3** CloudKit + Sign in with Apple sync — only if demand materializes.

---

## CI / CD

### Wired now
- ✅ `swift-test.yml` · `ios-build.yml` · `swiftlint.yml` · native Codex PR review · `secrets-scan.yml` (gitleaks) · `testflight.yml` · `.github/CODEOWNERS`.
- ✅ Xcode/sim pinned to 26.4.1 (iOS 26.4 SDK) via `setup-xcode@v1`, both build legs.
- ✅ `ios-test` is a required check on `main` (contexts: `test (Core)`, `test (Chat)`, `build`, `ios-test`, `lint`, `gitleaks`).

### Open
- [ ] **P1** Codecov — wire `codecov-action` into swift-test + ios-build; thresholds Core ≥80% / Chat ≥70% per `AGENTS.md`.
- [ ] **P1** Branch-protection rules on `main` per `docs/CI_PIPELINE.md` §7.2 (PR + 1 CODEOWNERS approval, required checks, linear history, no force-push). Apply via `gh api` once check names are registered.
- [ ] **P2** Notify-ready workflow per `docs/CI_PIPELINE.md` §11.2 (webhook when all checks pass).
- [ ] **P2** Tighten SwiftLint baseline (clear the ~15 known warnings, then `--strict`).
- [ ] **P2** Server CI — deferred until the server exists.

---

## Server (designed, not started)

Per `docs/SERVER_ARCHITECTURE.md`, `docs/CLIENT_SERVER.md`, `docs/AUTH.md`, `docs/SECURITY.md`. No `super-server/` in the repo yet; Chat runs fully on-device against BYOK endpoints.

- [ ] **P1** Scaffold `super-server/` (gateway, per-applet services, admin dashboard, Drizzle schema, Docker Compose for Postgres + Redis).
- [ ] **P1** First-run admin wizard at `/admin/setup`.
- [ ] **P1** JWT auth (refresh rotation, device-bound sessions) per `docs/AUTH.md`.
- [ ] **P1** LLM proxy (server holds the key) for the non-local-only privacy default.
- [ ] **P1** `GET /api/config` for client applet discovery.
- [ ] **P2** Deploy pipeline (Docker → registry → host).

## Sync engine (designed, not built)

Per `docs/SYNC.md`. Custom change-set protocol (not CloudKit); each install is local-only today.

- [ ] **P1** Client `SyncEngine`, last-write-wins per record.
- [ ] **P1** Server `/api/sync/push` + `/pull` + Drizzle `sync_changes` table.
- [ ] **P1** Conflict resolution for current record types.
- [ ] **P2** End-to-end encryption for synced payloads.

---

## Other applets (designed, not built)

Per `docs/PRODUCT_VISION.md` §4/§11 + `docs/CHAT_INTERACTIONS.md`. Each must implement the bi-directional contract (tools + chat cards + record actions + deep links).

- [ ] **P1** Recipes applet (§4.3).
- [ ] **P2** Finance applet (§4.5) — needs Plaid.
- [ ] **P2** Calendar applet (§11) — EventKit.
- [ ] **P2** Home applet (§11) — HomeKit.
- [ ] **P2** Notifications applet (§11).

*(ToDo and Bible applets are built — `Packages/Todo`, `Packages/Bible`.)*

## Shell

- [ ] **P1** Dynamic drag-resize with composer/pill morph: continuous rubber-band tracking during drag (snap-on-release today), composer and minimized pill animating as one shape. Separate PR.
- [ ] **P2** macOS Catalyst / native target (iOS only today; `SUPPORTS_MACCATALYST: NO`).
- [ ] **P2** iPad split-view layouts (per-form-factor snapshot baselines required).

## Cross-applet plumbing

- [ ] **P1** Shared chat-card renderer registry so any applet can render inline cards for its tool results.

*(`SuperEventBus` and long-press → Add-to-chat / Start-new-chat are built.)*

---

## Observability (designed, not wired)

Per `docs/OBSERVABILITY.md`. Apple-built-in only, no third-party SDKs. No telemetry in the binary today.

- [ ] **P2** MetricKit (`MXMetricManagerSubscriber`) — daily payloads, crash + hang diagnostics, on-device log for export.
- [ ] **P2** `os_log` category fan-out for Chat + Bible (`%{public}s` vs `%{private}s` discipline).
- [ ] **P2** Settings → About: "Export recent diagnostic log" row (reads `OSLogStore`).
- [ ] **P2** App Store Connect: confirm crash-report/analytics opt-ins for both targets.
- [ ] **P3** Server-side structured stdout (Pino) + platform log tailing.

## AI tooling

Per `docs/AI_TOOLS.md`. (Native Codex PR review is configured in Codex cloud; criteria live in `AGENTS.md`.)

- [ ] **P2** Standardize the agent-handoff protocol (branch naming, PR template, per-agent metadata) per `docs/CI_PIPELINE.md` §6.

---

## Open design questions

- `docs/CI_PIPELINE.md` §13 — 8 open questions (reviewer model, blocking vs non-blocking review, runners, Fastlane vs `xcodebuild`, migrations, agent self-merge, integration-test strategy, Xcode pinning). Decide before scaling agent activity.
- `docs/PRODUCT_VISION.md` §11 — open product questions on web / Android / Kotlin Multiplatform.
