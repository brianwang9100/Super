# SuperBible — Observability

> SuperBible follows the same observability posture as the rest of the project: **Apple-built-in only. No third-party SDKs.** This page is the SuperBible-specific restatement; the full posture, rationale, and code patterns live in [`../OBSERVABILITY.md`](../OBSERVABILITY.md).

---

## TL;DR

| Concern | Tool | Where the data lives |
|---|---|---|
| Crash reports | App Store Connect → Trends → Crashes | App Store Connect (opt-in, anonymous) |
| System metrics (launch, hangs, hitches, CPU, memory) | MetricKit (`MXMetricPayload`) | On device, JSONL under Application Support; user-exportable |
| Per-incident diagnostics (crash / hang / CPU / disk) | MetricKit (`MXDiagnosticPayload`) | Same as above |
| Structured logs | `os_log` with category fan-out | On device (Console.app + `OSLogStore`); user-exportable |
| Install / retention / version mix | App Store Connect → Analytics | App Store Connect (aggregated, anonymous) |
| Third-party SDKs | **None** | — |

---

## SuperBible-specific notes

- **One MetricKit subscriber is enough.** The `MetricKitManager` final class (per [`../OBSERVABILITY.md`](../OBSERVABILITY.md) §4.1) registers from `SuperBibleAppBootstrap` and is held on the dependency container for the app's lifetime. Payloads persist via the injected `DiagnosticLogStore` actor to `~/Library/Application Support/SuperBible/diagnostics.jsonl` (note: SuperOS persists to its own directory under `SuperOS/`; the two apps don't share state).
- **No analytics on personal study patterns.** Verse-reads, highlight color choices, plan-day completions, memorize streaks, quiz answers, chat messages: **never collected, never logged, never transmitted.** The closest thing to "product analytics" is App Store Connect's aggregate install + retention curves.
- **Settings → About → "Export recent diagnostic log"** is the one path by which any log data leaves the device, and the user is the one who chooses the destination (email, Files, AirDrop, GitHub issue). Nothing is sent anywhere automatically.
- **App Store privacy nutrition label** (per [`../OBSERVABILITY.md`](../OBSERVABILITY.md) §6.2) declares only crash / performance / diagnostic data, all via App Store Connect opt-in. Identifiers, product interaction, user content, location, contacts — none collected.

---

## What's surfaced in the app

A single Settings → About pane in SuperBible exposes:

- **App version + build number** — for bug reports.
- **Export recent diagnostic log** — wraps a short, user-controlled window of `os_log` entries (15-minute default, "Last hour" toggle) + recent MetricKit JSONL into a `.txt`, shows a pre-share preview, then presents the share sheet. Full posture in [`../OBSERVABILITY.md`](../OBSERVABILITY.md) §4.3.
- **Privacy** — links to `App-SuperBible/PRIVACY.md` (rendered in-app via a simple Markdown view).
- **Support development** — opens GitHub Sponsors in `SFSafariViewController`. Only shown once the Sponsors signup is live (per [`../superpowers/specs/2026-05-23-superbible-fork-design.md`](../superpowers/specs/2026-05-23-superbible-fork-design.md) §6.2).

No "Send analytics" toggle in-app, because there's no in-app analytics collection to toggle. The device-level "Share with App Developers" toggle in iOS Settings → Privacy & Security → Analytics & Improvements is what governs App Store Connect data — and that's the user's choice, not ours.

---

## Crash-rate signal

Target: `>99.5%` crash-free sessions, per [`../PRODUCT_VISION.md`](../PRODUCT_VISION.md) §12. Check App Store Connect → Trends → Crashes weekly during v1.x releases. If two consecutive weeks fall below the threshold, revisit whether the Apple-built-in posture is enough or whether something needs to change — but the *first* response is to read the crash stack traces, not to bring in a third-party SDK.

---

## Where this diverges from `../OBSERVABILITY.md`

It doesn't. This page is a restatement scoped to SuperBible, so a contributor reading the SuperBible folder doesn't have to chase cross-references to know the rules. If the project-wide doc and this one ever disagree, the project-wide doc wins — fix this one to match.
