# SuperBible App Target — Agent Rules

The composition root and target-specific assets for the **SuperBible** App Store app. Pairs with the SuperOS root at `App-SuperOS/` — both apps share `Core`, `Chat`, and `Bible` packages, plus the shared shell at `App/Shell/`; each target lives in its own folder and registers its own applet set. Full design + rationale: [`../docs/superpowers/specs/2026-05-23-superbible-fork-design.md`](../docs/superpowers/specs/2026-05-23-superbible-fork-design.md). Contributor one-pager: [`../docs/SuperBible/OVERVIEW.md`](../docs/SuperBible/OVERVIEW.md). Milestone status lives in the spec; do not duplicate it here.

## Module identity

- **Bundle ID:** `com.brianwang.SuperBible`
- **Display name:** `SuperBible`
- **Composition root:** `SuperBibleApp.swift` → `SuperBibleAppBootstrap` → `SuperBibleAppDependencies.shellDependencies` → shared `AppShell` (from `App/Shell/`)
- **Applet set (v1):** Chat (host) + Bible + Bookmarks *(present)* + Plans *(SB-M2)*
- **Applet set (post-v1, roadmap):** + Memorize, Quiz, Learn — each its own future spec
- **Deployment target:** iOS 26.0 (matches the SuperOS target's post-raise target)

### Launch behavior

SuperBible diverges from SuperOS deliberately on cold launch:

- **Active backdrop is always Bible.** The persisted active-applet id in `UserDefaults` is *deliberately ignored*. The bootstrap passes `BibleApplet.appletID` explicitly as `AppletRegistry.initialActiveID` on every cold launch, regardless of where the user navigated mid-session in the prior run. The applet array order (Chats, Bible) drives the sidebar rail order and is intentionally decoupled from the cold-launch backdrop. The shell's per-pick write to `UserDefaults` still fires (cheap, harmless dead weight here).
- **Chat overlay opens minimized.** The bootstrap passes `launchBehavior: AppShellLaunchBehavior(initialChatState: .minimized)` through `shellDependencies`. `AppShell.init` seeds both `chatState` and the matching `chatProgress` from it so the very first frame already renders the pill — no flash through `.expanded`.
- **Scope is cold launch only.** Foreground returns from background preserve whatever state the user left in (no scene-phase forced snap). Mid-session navigation to Chats / dragging the chat up is fully honored until the next cold launch.

If product later wants snap-back semantics on every foreground (`.active` scenePhase), extend `AppShellLaunchBehavior` rather than special-casing in either bootstrap.

## How the SuperBible chat persona is wired

- **Prompt source:** `App-SuperBible/Resources/SuperBibleSystemPrompt.md` — a markdown file bundled as a runtime resource via `project.yml`'s explicit `buildPhase: resources` entry. Edit this file to change the chat persona; no Swift recompile needed for prompt-only iteration in a future PR cycle.
- **Loader:** `App-SuperBible/SuperBibleSystemPromptLoader.swift` exposes `static func load() -> String`. Reads from `Bundle.main` via Core's shared `AppletSystemPrompt.load(from:resource:)` helper. The bootstrap calls it once and hands the result into `ChatSessionStore.init(chatBriefing:)`.
- **Divergence from SuperOS:** SuperOS uses `ChatBriefing.load()` (reads `DefaultSystemPrompt.md` from the Chat SwiftPM bundle — generic assistant persona). SuperBible substitutes its own biblical-study persona at this seam only; every other Chat surface is identical between the two targets.
- **Updating the persona later:** if a future revision changes what the assistant claims to be capable of (new tools, new applets, different scope), update `SuperBibleSystemPrompt.md` in the same PR — don't let the prose drift from the actual capabilities.
- **Persona principles + guardrails + eval:** the doctrinal stance (historic-creedal, non-neutral), the *describe-don't-prescribe* contested-topic guardrail, the crisis-handling rule, the response taxonomy, and the model-tier eval harness all live in [`../docs/SuperBible/PERSONA_EVAL.md`](../docs/SuperBible/PERSONA_EVAL.md). When you change the persona's behavior, re-run the eval (`.claude/workflows/superbible-persona-eval.js` over `eval/superbible-persona/corpus.json`) and keep that doc honest. The tool-routing half of the guardrail also lives in the Bible applet briefing (`../Packages/Bible/Sources/Bible/Resources/SystemPrompt.md`) — keep the two consistent.

> **Note:** Apple Intelligence (AFM) is currently non-functional for this persona — its ~4096-token window can't hold the full prompt + tool schemas. The persona is tuned and evaluated for the BYOK-Claude path; an AFM-specific disclaimer is separate, later work. See PERSONA_EVAL.md § "Out of scope — Apple Intelligence (AFM)".

## SuperBible-specific rules

These complement the root [`../AGENTS.md`](../AGENTS.md). When the root rules and these rules disagree, **these win for the SuperBible target.** They do not apply to SuperOS.

### LLM transport: BYOK-direct, no backend proxy

SuperBible has no server and will not get one for v1. Chat issues BYOK LLM calls **directly from device to provider** (Apple Foundation Models on-device by default; Anthropic / OpenAI / Ollama / etc. as opt-in BYOK upgrades). API keys live in the iOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

The root `AGENTS.md` § Backend rule "Backend proxies all LLM API calls (API keys never on client)" is a **SuperOS-only** rule. **Do NOT introduce a backend proxy for SuperBible.** If you find yourself wanting to, the right move is to refresh the fork spec §7 (Cloud roadmap) with the new evidence and discuss before writing code.

### No third-party SDKs (restated for App Store proximity)

The project-wide "no third-party SDKs" rule (Sentry, PostHog, Datadog, Crashlytics, Bugsnag, Firebase, Mixpanel, ad/attribution SDKs, OpenTelemetry, etc.) applies in full here. Restated because SuperBible is the App Store-facing target where the "just one SDK" temptation is highest at submission time. Observability is Apple-built-in only — see [`../docs/SuperBible/OBSERVABILITY.md`](../docs/SuperBible/OBSERVABILITY.md).

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

- SuperBible's snapshot tests run against the **same exact CI trio** as SuperOS (root-pinned Xcode 27 + iOS 27 simulator + iPhone 17 on `xcode-27`). The deployment minimum remains iOS 26.0.
- A SuperBible-specific snapshot suite isn't needed until the target has UI worth snapshotting (i.e., post-SB-M0). Until then, the shared package snapshot tests (Chat / Bible / Plans) cover the surface.
