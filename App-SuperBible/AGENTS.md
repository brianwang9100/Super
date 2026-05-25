# SuperBible App Target — Agent Rules

The composition root and target-specific assets for the **SuperBible** App Store app. Pairs with the SuperOS root at `App/` — both apps share `Core`, `Chat`, and `Bible` packages; each lives in its own folder and registers its own applet set. Full design + rationale: [`../docs/superpowers/specs/2026-05-23-superbible-fork-design.md`](../docs/superpowers/specs/2026-05-23-superbible-fork-design.md). Contributor one-pager: [`../docs/SuperBible/OVERVIEW.md`](../docs/SuperBible/OVERVIEW.md).

**Status (2026-05-24):** SB-M0 (target wired) and SB-M1 (composition root + Chat host + Bible) have shipped. Plans (SB-M2) is the next applet; not yet present.

## Module identity

- **Bundle ID:** `com.brianwang.SuperBible`
- **Display name:** `SuperBible`
- **Composition root:** `SuperBibleApp.swift` → `SuperBibleAppBootstrap` → `SuperBibleAppDependencies.shellDependencies` → shared `AppShell` (from `App/Shell/`)
- **Applet set (v1):** Chat (host) + Bible *(present)* + Plans *(SB-M2)*
- **Applet set (post-v1, roadmap):** + Memorize, Quiz, Learn — each its own future spec
- **Deployment target:** iOS 26.0 (matches the SuperOS target's post-raise target)

## How the SuperBible chat persona is wired

- **Prompt source:** `App-SuperBible/Resources/SuperBibleSystemPrompt.md` — a markdown file bundled as a runtime resource via `project.yml`'s explicit `buildPhase: resources` entry. Edit this file to change the chat persona; no Swift recompile needed for prompt-only iteration in a future PR cycle.
- **Loader:** `App-SuperBible/SuperBibleSystemPromptLoader.swift` exposes `static func load() -> String`. Reads from `Bundle.main` via Core's shared `AppletSystemPrompt.load(from:resource:)` helper. The bootstrap calls it once and hands the result into `ChatSessionStore.init(chatBriefing:)`.
- **Divergence from SuperOS:** SuperOS uses `ChatBriefing.load()` (reads `DefaultSystemPrompt.md` from the Chat SwiftPM bundle — generic assistant persona). SuperBible substitutes its own biblical-study persona at this seam only; every other Chat surface is identical between the two targets.
- **Updating the persona later:** if a future revision changes what the assistant claims to be capable of (new tools, new applets, different scope), update `SuperBibleSystemPrompt.md` in the same PR — don't let the prose drift from the actual capabilities.

## SuperBible-specific rules

These complement the root [`../AGENTS.md`](../AGENTS.md). When the root rules and these rules disagree, **these win for the SuperBible target.** They do not apply to SuperOS.

### LLM transport: BYOK-direct, no backend proxy

SuperBible has no server and will not get one for v1. Chat issues BYOK LLM calls **directly from device to provider** (Apple Foundation Models on-device by default; Anthropic / OpenAI / Ollama / etc. as opt-in BYOK upgrades). API keys live in the iOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

The root `AGENTS.md` § Backend rule "Backend proxies all LLM API calls (API keys never on client)" is a **SuperOS-only** rule. **Do NOT introduce a backend proxy for SuperBible.** If you find yourself wanting to, the right move is to refresh the fork spec §7 (Cloud roadmap) with the new evidence and discuss before writing code.

### No third-party SDKs (project-wide, restated)

No Sentry, PostHog, Datadog, Crashlytics, Bugsnag, Firebase, Mixpanel, Amplitude, AppsFlyer, Adjust, OpenTelemetry, ad SDKs, attribution SDKs. Observability is Apple-built-in only — see [`../docs/SuperBible/OBSERVABILITY.md`](../docs/SuperBible/OBSERVABILITY.md) and [`../docs/OBSERVABILITY.md`](../docs/OBSERVABILITY.md). This rule already lives in the root `AGENTS.md`; it's restated here because SuperBible is the App Store-facing target and the temptation to add a quick "just one SDK" is highest at submission time.

### No monetization beyond optional donations

Free. BYOK. No ads. No IAP. No premium tier. No paywalls. The only money-adjacent surface is a "Support development" row in Settings → About that opens GitHub Sponsors in `SFSafariViewController`. Documented in the fork spec §6.

### Privacy disclosures stay truthful

`PRIVACY.md` in this folder is the user-facing privacy policy, surfaced via a Settings → About → Privacy row at SB-M4. **Any change to what SuperBible collects, transmits, or stores requires a corresponding `PRIVACY.md` update in the same PR.** This includes:

- Adding an LLM provider type to the BYOK list (the policy already mentions BYOK generically; new specifics may need to be added).
- Adding any iOS capability (HealthKit, HomeKit, Location, Contacts, Calendar, Photos) — none of these are in scope for v1.
- Changing the Keychain accessibility attribute.
- Adding any network call outside the LLM-provider transport.

### Local-only v1; CloudKit as the v2 cloud path

v1 ships with no accounts, no server, no sync. **The planned v2 cloud path is Sign in with Apple + CloudKit private database — not a custom server.** Do not introduce auth, server endpoints, or a custom sync engine in SuperBible without first updating the fork spec §7.

## Testing expectations

Same as the root rules ([`../AGENTS.md`](../AGENTS.md) § Testing & Testability), with the SuperBible-specific note:

- SuperBible's snapshot tests run against the **same CI trio** as SuperOS (Xcode 26.4.1 + iOS 26.4 sim + iPhone 17 on `macos-26`).
- A SuperBible-specific snapshot suite isn't needed until the target has UI worth snapshotting (i.e., post-SB-M0). Until then, the shared package snapshot tests (Chat / Bible / Plans) cover the surface.
