# SuperBible Fork — Design Spec

> Brand a public, free, AI-first Bible app — **SuperBible** — as a second App Store target out of the existing `Super` monorepo. SuperOS stays as the personal/general productivity app. Both apps share `Core`, `Chat`, and `Bible`; each gets its own composition root and applet set.

**Status (2026-05-23):** Design approved. Not yet implemented.

---

## 1. Product framing

SuperBible is a chat-first AI Bible app: read scripture, follow reading plans, and converse with an AI about what you're reading. Free, BYOK (Bring Your Own Key), open source, local-first.

Public pitch line (used in `README.md`, App Store metadata, marketing):

> *SuperBible — a chat-first AI Bible app. Read scripture, follow plans, and converse with an AI about what you're reading. Free, BYOK, open source, local-first.*

Why ship this fork:
- **App Store-ready scope.** A multi-applet personal-productivity shell is too diffuse for a focused App Store launch. A Bible-only app is sharp, useful on day one, and a clean product story.
- **Differentiation comes from chat-empowered mini-apps.** Existing AI Bible apps are either chatbots glued onto static scripture, or static scripture with no chat at all. SuperBible's bi-directional contract (any verse → chat, any chat reference → verse, AI tools drive plan/memorize/quiz state) is a genuinely new shape.
- **Reuses what's built.** The Chat host (MVP M0–M12 complete) and Bible mini-app (already in the repo) are the bulk of v1. Only one new applet (Plans) blocks the v1 ship.

Default LLM at first launch: **Apple Foundation Models (AFM)** on-device — free, no key required, works offline. BYOK (Anthropic / OpenAI / Ollama / etc.) stays available as an upgrade path for stronger models. AFM is already seeded as the default `modelConfiguration` row per the existing project state; SuperBible inherits this for free.

SuperOS keeps every existing capability and roadmap (Todo, Recipes, Finance, Calendar, Home, server, sync) untouched. SuperOS is **not** going to the App Store; it remains the founder's personal app.

---

## 2. Architecture impact

SuperBible is purely additive. No core architectural change is required — every existing decision (MiniApplet protocol, event bus, GRDB per applet, SuperTheme in Core, BYOK + AFM default) already accommodates a second app target.

### 2.1 Repo layout (post-fork)

```
Super/
├── App/                          ← Shared shell only (compiled into both targets)
│   └── Shell/                    ← AppShell, AppShellDependencies, AppShellLaunchBehavior, …
├── App-SuperOS/                  ← SuperOS composition root
│   ├── SuperOSApp.swift          (renamed from SuperApp.swift)
│   ├── SuperOSAppBootstrap.swift (renamed from AppBootstrap.swift)
│   ├── SuperOSContentView.swift  (was ContentView.swift; renamed for symmetry)
│   ├── Info.plist
│   ├── Assets.xcassets
│   └── Placeholders/             (SuperOS-only placeholder applets)
├── App-SuperBible/         ← SuperBible composition root
│   ├── SuperBibleApp.swift
│   ├── SuperBibleAppBootstrap.swift
│   ├── SuperBibleContentView.swift
│   ├── Info.plist
│   ├── Assets.xcassets     (own icon, accent color, launch screen)
│   └── PRIVACY.md          ← user-facing privacy policy
├── Packages/
│   ├── Core/               (shared)
│   ├── Chat/               (shared)
│   ├── Bible/              (shared)
│   ├── Todo/               (SuperOS only)
│   ├── Plans/              ← NEW (SuperBible)
│   ├── Memorize/           ← NEW, post-v1 (SuperBible)
│   ├── Quiz/               ← NEW, post-v1 (SuperBible)
│   └── Learn/              ← NEW, post-v1 (SuperBible)
├── Scripts/xcodegen-extras/
│   ├── Chat.xcscheme       (existing — package test scheme)
│   ├── Bible.xcscheme      (existing — package test scheme)
│   ├── Todo.xcscheme       (existing — package test scheme)
│   └── (Plans/Memorize/Quiz/Learn package schemes added as packages land)
├── Config/
├── docs/
└── Super.xcodeproj
```

### 2.2 Xcode project changes

In `project.yml`:

- New target `SuperBible`:
  - `type: application`, `platform: iOS`, `deploymentTarget: "26.0"` (matches the existing target's planned iOS 26 raise per the in-flight default-model design work; if `project.yml`'s `Super` target still reads `18.0` at the time the SuperBible target is added, raise it in the same commit so both targets stay aligned).
  - `sources: [{path: App-SuperBible}]`.
  - `info.path: App-SuperBible/Info.plist` with `CFBundleDisplayName: SuperBible` and the same ATS / speech / microphone keys as the SuperOS target.
  - `settings.base.PRODUCT_BUNDLE_IDENTIFIER: com.brianwang.SuperBible`, `PRODUCT_NAME: SuperBible`.
  - `dependencies: [Core, Chat, Bible, Plans]` for v1; appends `Memorize`, `Quiz`, `Learn` as those packages land.
- New scheme `SuperBible` declared inline in `project.yml`'s `schemes:` block, mirroring the existing `Super` scheme. **xcodegen generates the app-level scheme automatically** — no hand-maintained `SuperBible.xcscheme` in `Scripts/xcodegen-extras/`. The hand-maintained files in `xcodegen-extras/` exist solely for SPM-package test schemes (Chat, Bible, Todo, and future Plans/Memorize/Quiz/Learn), which xcodegen 2.45.4 can't model from `project.yml`. App-level schemes are out of that scope.
- `postGenCommand` is unchanged for the SuperBible target itself; it still only copies the per-package test schemes.

The existing `Super` target is otherwise unchanged. The two file renames in `App/` (`SuperApp.swift` → `SuperOSApp.swift`, `AppBootstrap.swift` → `SuperOSAppBootstrap.swift`) landed in the same commit as the SuperBible target wiring so both apps adopt the symmetric naming (`SuperOSApp` + `SuperOSAppBootstrap` ↔ `SuperBibleApp` + `SuperBibleAppBootstrap`) at the same time. `@main` annotation and any internal references updated to match. Post-SB-M1, the SuperOS files moved from `App/` to `App-SuperOS/` for full directory symmetry with `App-SuperBible/`, and the remaining SuperOS-only type names (`ContentView`, `BootstrapState`, `AppDependencies`) were prefixed to match (`SuperOSContentView`, `SuperOSBootstrapState`, `SuperOSAppDependencies`).

### 2.3 Composition root

`App-SuperBible/SuperBibleApp.swift` is a near-mirror of `App-SuperOS/SuperOSApp.swift` (parallel `SuperOSBootstrapState` / `SuperBibleBootstrapState` machines, the same `.task` load pattern). It calls `SuperBibleAppBootstrap.bootstrap()`, which differs from `SuperOSAppBootstrap.bootstrap()` only in the applet set it registers:

- Both bootstraps reuse Core services (event bus, GRDB factories, Keychain, model registry, SuperTheme).
- Both bootstraps register Chat as the host.
- `SuperOSAppBootstrap` registers Bible + Todo.
- `SuperBibleAppBootstrap` registers Bible + Plans.

The applet registration list is the only meaningful difference between the two roots; everything else delegates into shared Core / Chat code.

A SuperBible-specific Chat system prompt (per the per-applet system-prompt pattern from PR #75) frames the assistant's persona for biblical-study conversations. The prompt text lives in the SuperBible bootstrap; everything else about Chat is shared verbatim.

### 2.4 Shared theme

`SuperTheme` in Core (per the in-tree pattern from PR #41) provides both apps with the OKLCH palette today. SuperBible v1 uses the same palette as SuperOS to keep scope minimal. A distinct cohesive Bible-themed palette is a deliberate v1.x polish item, **not** a v1 blocker.

### 2.5 Code that is explicitly NOT shared

- App icons and accent colors (per-target asset catalog).
- App Store metadata.
- Privacy policy (`App-SuperBible/PRIVACY.md` only).
- Donation surface (Settings → About in SuperBible only).
- Applet registration list (the bootstrap files diverge here and nowhere else).

---

## 3. Mini-app set & roadmap

### 3.1 v1 ship (App Store)

| Applet | Status | Notes |
|---|---|---|
| **Chat** | Built (M0–M12) | Host. Default LLM = AFM on-device. BYOK upgrade path. SuperBible-specific system prompt. |
| **Bible** | Built | Drop in unchanged. Long-press-to-chat + tappable canonical-reference tokens already work. |
| **Plans** | NEW | Bible reading plans. Daily check-in. Streaks. Full bi-directional contract. |

### 3.2 Plans applet — v1 scope sketch

This spec does not design the Plans applet in detail (that's a separate brainstorm → spec → plan cycle when its turn arrives). The scope shape for budgeting:

- **Data model** (GRDB structs): `ReadingPlan`, `PlanDay`, `PlanProgress`, `PlanStreak`. Bundled-plan content lives in a `Resources/` JSON-per-plan file (same pattern Bible uses for `WEB-<bookID>.json`).
- **Bundled plans for v1:** F260, M'Cheyne, Bible in a Year, Bible in 90 Days. Add more in v1.x.
- **Reactive binding via GRDBQuery** (per the project convention from the Todo applet) — Plans can be marked read from multiple paths (the day view, the plan-list view, Chat tools), so the binding is reactive, not pull-based.
- **Tools registered with Chat:** `plans.list`, `plans.start(planId)`, `plans.today`, `plans.markRead(planId, day)`, `plans.streak(planId)`.
- **Chat-card renderers:** today's reading, plan progress, streak summary, completion confirmation.
- **Long-press actions on a plan day:** Mark read / Mark unread / Open in Bible / **Add to current chat** / **Start new chat with this**.
- **Deep-link target:** `super://plans/<planId>/<day>`.
- **Local daily notification** at user-configured time (default 8am local) reminding the user of today's reading.

### 3.3 Post-v1 roadmap

Each is its own future spec — listed here, not designed:

- **Memorize** — Spaced-repetition verse memorization with a daily review queue.
- **Quiz** — AI-generated Bible knowledge quizzes. Difficulty levels, history, streaks.
- **Learn** — Guided theology learning paths. Topic-organized study modules.

### 3.4 Explicitly NOT in SuperBible

Todo, Recipes, Finance, Calendar, Home, Notes, Habit, Fitness, Notifications Hub, any general-productivity applet. These stay SuperOS-only.

### 3.5 Milestone plan

| ID | Milestone | Deliverable |
|---|---|---|
| **SB-M0** | Target wired up | `SuperBible` target builds. Launches a stub Shell. CI green on the new build. |
| **SB-M1** | Composition root + applet registration | Chat + Bible registered. SuperBible-specific system prompt. App is usable end-to-end minus Plans. |
| **SB-M2** | Plans core | Plans package: schema, read view, tools, chat cards, long-press actions, deep-link target. |
| **SB-M3** | Plans content + onboarding | Bundled plans (F260, M'Cheyne, Bible in a Year, Bible in 90 Days). Daily notification. Reading streak. Onboarding (pick a plan, set notification time). |
| **SB-M4** | App Store polish | Final icon, screenshots, App Privacy nutrition label, App Store Connect metadata, donation link in Settings → About, `PRIVACY.md`, TestFlight beta. |
| **SB-M5** | App Store ship | Submission, review, release. |

SB-M6+ post-launch: Memorize, Quiz, Learn — each gated on real user feedback.

---

## 4. Observability & crash detection

**Apple-built-in only. No third-party SDKs. Project-wide commitment, not just SuperBible.**

Reasoning (applies to both apps):

- Free + privacy-first + open source: every third-party SDK is a privacy surface to disclose in the App Privacy nutrition label, a recurring third-party cost the project can't justify, and a thing users will see in the open-source repo and (rightly) question.
- Apple's built-ins are already paid for, require zero SDK weight, and respect the device-level analytics opt-in.

### 4.1 Client-side observability — what we use

- **App Store Connect crash reports.** Symbolicated stack traces per release. Free. No SDK. No user-identifiable data. User opt-in via the iOS device-level analytics toggle.
- **MetricKit** (`MXMetricManager`):
  - `MXCrashDiagnostic` — runtime crashes with stack traces.
  - `MXHangDiagnostic` — main-thread hangs.
  - `MXCPUExceptionDiagnostic` — CPU runaways.
  - `MXDiskWriteExceptionDiagnostic` — disk pressure events.
  - Daily payloads of app launch time, hang rate, animation hitch rate, peak memory.
  - Payloads persist to an on-device debug log the user can manually share when filing an issue.
- **App Store Connect Analytics** — install counts, retention curves, country / device / OS breakdowns by version. Aggregated. Anonymous. Free.

### 4.2 Server-side observability — when the SuperOS server exists

- **Structured stdout / platform logs** (Fly.io / Railway / hosting-platform native log shipping). No external log aggregator (no Datadog, no Honeycomb, no New Relic, no OpenTelemetry collector).
- **Platform-native uptime + alerting** from the chosen host's built-in dashboards.
- The bar to add a third-party server-side service: a concrete operational pain that platform-native tools demonstrably can't address, raised as an issue with a written rationale.

### 4.3 What we explicitly do NOT collect (project-wide)

- Verse-text content the user reads, highlights, or notes.
- Chat message text (user or assistant), tool-call arguments, or tool-call results.
- Reading-plan progress as user-identifiable trajectories.
- Task titles / descriptions (SuperOS Todo).
- Any PII.

This is stated in `App-SuperBible/PRIVACY.md` and the App Store privacy nutrition label.

### 4.4 Crash-rate signal

Both apps target `>99.5%` crash-free sessions (the existing `PRODUCT_VISION.md` §12 target). If a release drops below that threshold for two consecutive weeks, revisit whether the Apple-built-in telemetry is enough or whether something richer is needed. **Do not** preemptively add Sentry / PostHog / Datadog — the bar is a demonstrated need, not a hypothetical one.

---

## 5. CI strategy

The constraint: adding a second app target must not meaningfully balloon CI time or runner-minute spend for typical PRs.

### 5.1 Posture

**Both targets build on every PR, in parallel, with shared derived-data cache.** Tests stay in packages (run via `swift-test.yml`), not in `ios-build`. Docs-only PRs skip `ios-build` entirely.

No path-filter matrix on the app builds. Always build both. Rationale:

- Path-filter rules are brittle — false negatives ship merge-time surprises. Cost of being wrong (a broken target landing on `main`) exceeds the cost of the duplicate cached build.
- Parallel + cached, the wall-clock impact is small. Runner-minutes are free on public GitHub Actions for open-source repos.

### 5.2 What changes in CI

- `ios-build.yml` adds a second job matrix entry: `scheme: [Super, SuperBible]`. Both run in parallel on macos-26 with Xcode 26.4.1 + iOS 26.4 simulator on iPhone 17 (the pinned CI trio per `AGENTS.md`).
- `actions/cache` keyed on `hashFiles('**/Package.resolved', 'project.yml')` over `~/Library/Developer/Xcode/DerivedData`. Both app-build jobs share this cache — second build mostly hits cache for Core / Chat / Bible.
- `swift-test.yml` matrix auto-discovery (open TODO from `TODO.md` § CI gaps) lands first so new packages (Plans / Memorize / Quiz / Learn) join the test matrix as they appear, without per-package workflow edits.
- `testflight.yml` parameterized by scheme so it can ship either target. New tag conventions: `release/super-v*` ships SuperOS; `release/superbible-v*` ships SuperBible. Each tag triggers a single-target archive.
- Branch protection on `main` updated to require both `ios-build (Super)` and `ios-build (SuperBible)` as separate checks.
- `paths-ignore` on `ios-build.yml` is **added** (not yet present today) so docs-only PRs skip both target builds: `docs/**`, `*.md`, `TODO.md`, `README.md`, `**/AGENTS.md`, `**/CLAUDE.md`. Tracked as a SB-M0 TODO item alongside the second-target matrix wiring.

### 5.3 Wall-clock targets

- Baseline today (`Super` only): ~8 min cold, ~3 min cached.
- With two targets, parallel, shared cache: ~8 min cold, ~3–4 min cached. **No meaningful regression for typical PRs**, because the dominant cost (shared-package compile) is hit by the cache and the parallel runners absorb the duplicate target-specific work.

### 5.4 Risks + mitigations

- **Cache key drift** — a stale cache hiding a real build issue. Mitigation: include `project.yml` hash in the cache key so target-shape changes invalidate. Keep `Package.resolved` in source control so SPM resolves are deterministic.
- **Path filter brittleness** — explicitly avoided by not using one for app builds.
- **Runner-minute spend on a future private repo** — if SuperBible's repo ever goes private, the 2× runner-minutes become a real cost. Mitigation: at that point, fall back to the smart-matrix path filter (originally proposed). Documented here as the contingency.

---

## 6. Monetization

### 6.1 Posture

Free. BYOK. No ads. No IAP. No premium tier. No paywalls. **Documented as a deliberate v1.x constraint, not a TBD.**

### 6.2 Donation surface

- **Single surface:** Settings → About pane in SuperBible only. A "Support development" row opens `https://github.com/sponsors/brianwang9100` via `SFSafariViewController`. **Prerequisite for SB-M4:** complete the GitHub Sponsors signup flow for the `brianwang9100` account before App Store submission. If Sponsors approval is still pending at SB-M4, the "Support development" row is hidden behind a feature flag and shipped in the first post-launch update — donation surface is not a launch blocker.
- **No donation surface in SuperOS.** SuperOS is the founder's personal app.
- **No third-party donation widgets in-app.** No Patreon SDK, no Ko-fi SDK, no Stripe widget. The link opens a web view; that's it.

### 6.3 Account / login

SuperBible v1 has no sign-in, no account, no server. The app is fully usable on first launch with zero configuration (AFM seeded as the default model).

### 6.4 Non-profit decision

**Deferred.** Documented criterion to revisit: donations cross ~$50k/year, or a substantial donor needs tax-deductibility. Until then, donations are received by the founder as personal income; no 501(c)(3) overhead (incorporation, board, IRS Form 1023, annual Form 990, state filings, restricted activities, hard-to-undo governance).

### 6.5 License

MIT (the existing `LICENSE`). Applies to both apps from one repo.

---

## 7. Cloud roadmap

### 7.1 v1: local-only

GRDB-on-device for every applet (Chat conversations, Bible highlights, Plans progress). No auth. No server. No sync. No remote LLM proxy — BYOK LLM calls go directly from device to provider, same as current SuperOS.

### 7.2 v2 contingent on traction: CloudKit + Sign in with Apple

If SuperBible takes off and users start asking for cross-device sync, the planned upgrade path is **Sign in with Apple + CloudKit private database** — not a custom server. Rationale:

- Free up to generous quotas (Apple's free tier covers 99% of indie scenarios).
- No infra to operate. No auth system to build. No PII to store.
- Apple-only is acceptable for SuperBible (iOS-first product).
- Respects user privacy by design — data sits in the user's own iCloud, not on our infra.

### 7.3 SuperOS keeps its existing plan

The existing `docs/SERVER_ARCHITECTURE.md` / `docs/CLIENT_SERVER.md` / `docs/AUTH.md` / `docs/SYNC.md` plans for SuperOS (TypeScript + Hono + Drizzle + Postgres + Redis + custom sync) are unchanged. The two apps have different cloud strategies because they have different user models (one personal user vs many public users).

---

## 8. Doc-update plan

The following existing docs get edited in the SuperBible-fork PR, alongside the new `App-SuperBible/` and `Packages/Plans/` work landing across SB-M0 through SB-M4. Edits are concrete and surgical — no full rewrites.

| Doc | Change |
|---|---|
| `README.md` | Top-of-file: reframe as "Super — a monorepo containing two apps: SuperOS (personal AI productivity, in development) and SuperBible (free AI Bible app, App Store target)." Add SuperBible pitch line. |
| `docs/PRODUCT_VISION.md` | Add new §13 "App targets: SuperOS vs SuperBible" — short, points at this spec. Mark Bible §4.4 as "shared between SuperOS and SuperBible." In §11 (Open Questions) mark the monetization question resolved with a pointer to §6 of this spec. (Old §13 "Document Index" renumbers to §14.) |
| `docs/OBSERVABILITY.md` | Strip third-party SDK recommendations (Sentry, PostHog, Datadog, OpenTelemetry, anything similar). Reframe around Apple built-ins for the client and platform-native logs for the server. Update the status banner. Add a "Why no third-party SDKs" rationale section citing §4 of this spec. |
| `docs/DESIGN.md` | One paragraph noting that the same shell + applet manager serves both app targets; per-target composition decides applet membership. |
| `docs/CI_PIPELINE.md` | Document the two-target `ios-build` matrix, shared derived-data cache, and `release/super-v*` vs `release/superbible-v*` tag conventions for `testflight.yml`. |
| `docs/DEVELOPMENT_SETUP.md` | Add per-target build/run instructions (which scheme builds which app). |
| `TODO.md` | New top-level section "SuperBible (App Store target)" with milestones SB-M0 through SB-M5. |
| `App-SuperBible/PRIVACY.md` | **NEW.** User-facing privacy policy: what's collected (essentially nothing), what's stored locally only, what AFM and BYOK providers do with data, the no-third-party-SDKs commitment. Linked from Settings → About. |
| `docs/SuperBible/OVERVIEW.md` | **NEW.** One-pager intro to the SuperBible target for new contributors. Links to this spec, `App-SuperBible/PRIVACY.md`, and the (future) per-applet docs. |
| `docs/SuperBible/OBSERVABILITY.md` | **NEW.** Apple-only posture for the SuperBible target. Cross-references the project-wide `docs/OBSERVABILITY.md` to explain why they agree. |

### 8.1 Docs explicitly unchanged

These docs need no edits because SuperBible v1's local-only / no-server / no-auth posture means they describe SuperOS-only concerns:

`AUTH.md`, `SERVER_ARCHITECTURE.md`, `CLIENT_SERVER.md`, `SYNC.md`, `SECURITY.md`, `MOBILE_ARCHITECTURE.md`, `CHAT_INTERACTIONS.md`, `AI_TOOLS.md`, `NAMING_CONVENTIONS.md`.

---

## 9. Open questions deferred to future specs

- **Plans applet detailed design** — bundled-plan format, day-cell layout, streak rules, notification-time defaults, onboarding flow. Own brainstorm → spec → plan cycle before SB-M2 starts.
- **Memorize / Quiz / Learn applet detailed designs** — each its own future spec, post-v1.
- **SuperBible-specific theme palette** — v1.x polish. Currently inherits SuperOS palette.
- **CloudKit migration plan** — only specified once SuperBible v1 ships and user-demand signal exists.
- **Localization strategy** — v1 is English only. Multi-language Bible support and UI localization are post-v1.
- **Audio Bible / TTS** — explicitly deferred. Not v1.
- **Widgets / Live Activities / Lock Screen** — explicitly deferred. Not v1.
- **App Clip for plan-day sharing** — explicitly deferred. Not v1.

---

## 10. Success criteria

For the fork itself (this spec):

- SuperBible builds as its own target with its own bundle ID, icon, App Store identity.
- CI builds both targets on every PR; wall-clock regression < 50% vs baseline for typical (cached) PRs.
- Zero third-party observability SDKs introduced to the project.
- Zero changes required to existing applet protocols, the event bus, Core services, or the Chat host to support the second target.
- Existing SuperOS user flows continue to work unchanged after the fork lands.

For SuperBible v1 in the App Store (downstream of the fork):

- AFM-default chat works on first launch without configuration.
- Bible + Plans bi-directional contract demoably works end-to-end (verse → chat → tool → mini-app update → animation).
- Crash-free sessions > 99.5% on TestFlight before public release.
- App Store review passes on first submission (no rejections for missing privacy disclosures, missing functionality, or paywall confusion).
