# SuperBible — Overview

> A chat-first AI Bible app. Read scripture, follow plans, and converse with an AI about what you're reading. Free, BYOK (Bring Your Own Key), open source, local-first.

**Status (2026-05-23):** Designed, not yet wired. Target lands at milestone SB-M0 — see [`../../TODO.md`](../../TODO.md) § SuperBible.

---

## What this is

SuperBible is one of **two app targets** in this monorepo. The other is **SuperOS** (the founder's personal AI productivity app). Both apps share the same `Core` package, the same `Chat` host, and the same `Bible` mini-app — they differ only in which mini-apps each one registers at launch.

See [`PRODUCT_VISION.md` §13](../PRODUCT_VISION.md#13-app-targets-superos-vs-superbible) for the side-by-side, and [`superpowers/specs/2026-05-23-superbible-fork-design.md`](../superpowers/specs/2026-05-23-superbible-fork-design.md) for the full design and rationale.

---

## v1 mini-apps

| Mini-app | Status | Role |
|---|---|---|
| **Chat** | Built (Super MVP M0–M12) | Host surface. Default LLM = Apple Foundation Models on-device (free, offline, no key). BYOK upgrade for stronger models. SuperBible-specific system prompt framed for biblical-study conversations. |
| **Bible** | Built | Reading, search, highlights, notes, deep-linkable references. Bi-directional with Chat. |
| **Plans** | New (SB-M2) | Bible reading plans (F260, M'Cheyne, Bible in a Year, Bible in 90 Days). Daily check-in, streaks, local notifications. |

Post-v1 roadmap: **Memorize** (spaced-repetition verse memorization), **Quiz** (AI-generated Bible knowledge quizzes), **Learn** (guided theology learning paths). Each gets its own brainstorm → spec → plan cycle.

---

## Principles

SuperBible inherits everything from `PRODUCT_VISION.md` §2 (chat is the host, bi-directional AI, offline-first, privacy-by-default, design-first). The SuperBible-specific stances on top:

- **Free, BYOK, no ads, no IAP, no paywalls.** Optional GitHub Sponsors link in Settings → About. No premium tier — ever.
- **No third-party SDKs.** No Sentry, PostHog, Datadog, analytics SDKs, ad SDKs, attribution SDKs. Apple-built-in observability only — see [`OBSERVABILITY.md`](./OBSERVABILITY.md).
- **Local-only v1.** No accounts. No server. No sync. The app works fully on first launch with zero configuration.
- **CloudKit is the planned v2 cloud path** — Sign in with Apple + CloudKit private database — but only if cross-device sync demand materializes. No commitment to building a custom server for SuperBible.
- **iOS-first.** macOS and other platforms are deliberately out of scope until v1 ships and signal warrants more.

---

## Architecture

No architectural changes vs SuperOS — purely additive. SuperBible shares the same `MiniApplet` protocol, the same event bus, the same GRDB-per-applet pattern, the same `SuperTheme` in Core, the same bi-directional contract for tool calls and chat cards.

The only thing different per target is the composition root:

- `App-SuperOS/SuperOSApp.swift` → `SuperOSAppBootstrap` → Chat + Bible + Todo (and more, over time).
- `App-SuperBible/SuperBibleApp.swift` → `SuperBibleAppBootstrap` → Chat + Bible + Plans (and more, post-v1).

Bundle ID: `com.brianwang.SuperBible`. Display name: `SuperBible`.

---

## Pointers

- **Fork design + milestones (SB-M0–M5):** [`superpowers/specs/2026-05-23-superbible-fork-design.md`](../superpowers/specs/2026-05-23-superbible-fork-design.md)
- **Observability posture (Apple-built-in only):** [`OBSERVABILITY.md`](./OBSERVABILITY.md)
- **User-facing privacy policy (when SB-M4 lands):** `../../App-SuperBible/PRIVACY.md`
- **Cross-applet interactions catalog (shared with SuperOS):** [`../CHAT_INTERACTIONS.md`](../CHAT_INTERACTIONS.md)
- **Open backlog:** [`../../TODO.md`](../../TODO.md) § SuperBible
