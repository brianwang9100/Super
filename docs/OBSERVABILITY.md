# Super: Observability

> Full-stack observability strategy for the Super monorepo (SuperOS + SuperBible apps, plus the future SuperOS server). **Apple-built-in only on the client. Platform-native logs only on the server. No third-party observability SDKs anywhere in the project.**

**Prerequisite reading:** [MOBILE_ARCHITECTURE.md](./MOBILE_ARCHITECTURE.md) for client-side architecture, [SERVER_ARCHITECTURE.md](./SERVER_ARCHITECTURE.md) for backend topology, [PRODUCT_VISION.md](./PRODUCT_VISION.md) for applet descriptions, [`superpowers/specs/2026-05-23-superbible-fork-design.md`](./superpowers/specs/2026-05-23-superbible-fork-design.md) §4 for the rationale behind the no-third-party-SDKs commitment.

> **Status (2026-05-23):** Strategy revised. Earlier drafts of this document recommended Sentry + PostHog + Datadog as the launch posture; that recommendation is **withdrawn** project-wide. The new posture is below. Nothing is wired in the binary yet — see [`TODO.md`](../TODO.md) § Observability for the open work.

---

## 1. Why no third-party SDKs

Both apps in this repo (SuperOS and SuperBible) commit to the same posture: **no third-party observability SDKs**. The reasoning:

- **Open source.** Every third-party SDK is a thing users can see in the public repo and will (rightly) question — "why is this free Bible app sending data to Sentry?" Even with privacy controls, the optics work against trust.
- **Privacy nutrition label.** Each SDK adds rows to the App Store privacy disclosure. The shorter that list, the easier it is to be both truthful and reassuring.
- **Cost.** SuperBible is free with no monetization beyond optional donations. A recurring third-party SaaS bill — even on a free tier with a paid upgrade path — is hard to justify and harder to budget around.
- **Binary weight.** A typical observability SDK adds 1–3 MB to the binary. For a free app where the alternative is "use Apple's built-in tools that ship with iOS," it's a poor tradeoff.
- **Lock-in.** Once an SDK is integrated and breadcrumbs / events / dashboards depend on it, ripping it out becomes a project of its own. Better to never depend on it.

The bar to revisit: a concrete operational pain that Apple's built-ins demonstrably can't address, raised as an issue with a written rationale. Not "this would be nicer" — "this is causing a specific harm we cannot otherwise mitigate."

---

## 2. Goals

Observability serves four distinct purposes:

| Goal | What it answers |
|------|----------------|
| **Crash visibility** | When the app crashes, what happened? How many users are affected? Is it getting worse? |
| **Performance awareness** | Is the app fast? Are launches slow? Are there hangs? Is animation hitching? |
| **Product signal** | How many people installed? Are they returning? Which versions are in the field? |
| **Operational awareness** *(server, when it exists)* | Is the server up? Are errors rising? Is the database under pressure? |

**Non-goals:**
- Surveillance. No tracking of message content, verse text, task titles, plan progress, or any user-generated text.
- Per-user behavioral analytics. We don't need (and don't want) "user X opened the app 14 times this week."
- Custom dashboards on third-party services. App Store Connect + Xcode Organizer are the dashboards.
- Real-time paging / on-call rotations. This is a solo-dev project; alerts are async by design.

---

## 3. Pillars

The four classic observability pillars, scoped to what Apple's built-ins actually deliver:

### 3.1 Crash reports

Symbolicated stack traces for every crash on a TestFlight or App Store build. Source: **App Store Connect → Trends → Crashes** (also called the Xcode Organizer crashes tab). Free, no SDK, no in-app code, no user-identifiable data. Users opt in via the device-level "Share with App Developers" toggle (iOS Settings → Privacy & Security → Analytics & Improvements; macOS System Settings → Privacy & Security → Analytics & Improvements).

**Symbolication requires dSYM upload to App Store Connect.** This is *not* automatic — it depends on the archive-time configuration:

- Xcode's *Archive → Distribute App* flow uploads dSYMs by default. Confirm the "Upload Symbols to App Store Connect" checkbox stays ticked in the distribution dialog.
- For our `testflight.yml` CI pipeline (per [`CI_PIPELINE.md`](./CI_PIPELINE.md) §9.2): `xcodebuild -exportArchive` with an `ExportOptions.plist` containing `<key>uploadSymbols</key><true/>` is what wires the upload. If this key is missing or false, crashes ship as raw hex addresses and the >99.5% crash-free target becomes unactionable because nobody can read the traces.
- Bitcode is deprecated since Xcode 14, so the historical "App Store re-compiles + re-symbolicates" path no longer applies. dSYMs must be uploaded; that's the only mechanism.

Verify after each release: Xcode Organizer → Crashes → Open in Project. If a build's crashes show as `0x100abcdef` instead of function names, dSYMs didn't make it — re-upload via Xcode Organizer's "Upload Debug Symbols" action.

### 3.2 System metrics

Daily aggregated payloads delivered via **MetricKit** (`MXMetricManager`):

| Payload | What it measures |
|---|---|
| `MXAppLaunchMetric` | Histogram of cold launch time, time to first frame. |
| `MXAppResponsivenessMetric` | Histogram of main-thread hang durations. |
| `MXAppExitMetric` | Why the app last exited (crash, watchdog, OOM, normal). |
| `MXCPUMetric` | CPU time cumulative + per-second. |
| `MXMemoryMetric` | Peak memory footprint. |
| `MXDiskIOMetric` | Bytes written. |
| `MXAnimationMetric` | Frame hitch rate. |
| `MXDisplayMetric` | Average luminance of pixels the app rendered (useful for OLED power analysis, *not* a measurement of device brightness or ambient light). |

### 3.3 Diagnostics

On-demand per-incident reports via `MXMetricManager` `didReceive(_ payloads: [MXDiagnosticPayload])`:

- `MXCrashDiagnostic` — crash stack trace + thread state.
- `MXHangDiagnostic` — main-thread hang stack trace.
- `MXCPUExceptionDiagnostic` — CPU runaway.
- `MXDiskWriteExceptionDiagnostic` — runaway disk write.

Diagnostics get persisted to an on-device debug log the user can manually export via Settings → About → "Export recent diagnostic log" when filing an issue. They are **not** automatically transmitted anywhere.

### 3.4 Structured logs

`os_log` for everything. Apple-native, performant, free, with built-in `%{public}s` vs `%{private}s` redaction. On-device only by default — readable in Console.app when a device is connected to a Mac, exportable via `OSLogStore` for user-initiated bug reports.

---

## 4. Client implementation

### 4.1 MetricKit subscriber

`MXMetricManagerSubscriber` refines `NSObjectProtocol`, so the conformer must be a class (an actor can't inherit from `NSObject`). Make it a `final class` and route the actual file I/O through an internal `actor` so writes are serialized without blocking the MetricKit delivery thread:

```swift
import MetricKit

final class MetricKitManager: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitManager()

    private let store = DiagnosticLogStore()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            Task { await store.append(payload.jsonRepresentation(), kind: "metric") }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            Task { await store.append(payload.jsonRepresentation(), kind: "diagnostic") }
        }
    }
}

/// Serializes appends to the diagnostics JSONL. Rotates at ~5 MB.
actor DiagnosticLogStore {
    func append(_ data: Data, kind: String) async {
        // Append a JSONL row under the app's Application Support directory.
        // Users can export the file via Settings (see §4.3).
    }
}
```

The rotated JSONL lives at `~/Library/Application Support/SuperOS/diagnostics.jsonl` (and the SuperBible-bundle equivalent). Never transmitted. Only the user can read it.

### 4.2 os_log categories

```swift
import os.log

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.brianwang.Super"

    static let general    = Logger(subsystem: subsystem, category: "general")
    static let chat       = Logger(subsystem: subsystem, category: "chat")
    static let bible      = Logger(subsystem: subsystem, category: "bible")
    static let database   = Logger(subsystem: subsystem, category: "database")
    static let network    = Logger(subsystem: subsystem, category: "network")
    static let llm        = Logger(subsystem: subsystem, category: "llm")
    static let eventBus   = Logger(subsystem: subsystem, category: "event_bus")
    static let perf       = Logger(subsystem: subsystem, category: "perf")
}
```

**Discipline:**
- Identifiers, opcodes, tool names, durations → `%{public}`.
- Anything user-authored (message content, verse text, task titles, notes, file paths inside user data) → `%{private}` *or omitted entirely* — when in doubt, omit.
- Error descriptions: use `%{public}` only when you're sure the error message doesn't echo user input (e.g. `error.localizedDescription` for a network failure is fine; for a JSON-decoding failure of a user message, it might leak content — omit).

### 4.3 Log export for bug reports

Settings → About → "Export recent diagnostic log" reads a short, user-controlled window of entries from `OSLogStore` plus the rotated MetricKit JSONL, packages them as a single `.txt`, and presents the system share sheet. The user decides where the file goes (email to the maintainer, paste into a GitHub issue, etc.) — nothing leaves the device automatically.

**Privacy posture on the export flow:**

- **Short default window.** 15 minutes from "now" — long enough to capture a reproducing crash + the surrounding actions, short enough that the file rarely picks up unrelated history. A "Last hour" toggle is the only longer option offered; longer windows are deliberately not exposed.
- **Pre-share preview.** Before the share sheet appears, show the user the exact text being shared (`UITextView` over a sheet, "Cancel" or "Continue"). They see what's leaving the device.
- **Subsystem filter is mandatory.** Only entries whose `subsystem == Bundle.main.bundleIdentifier` are included — never the user's other apps.
- **MetricKit JSONL is included verbatim.** Crash and hang stack traces may contain symbolicated function names from third-party Swift libraries (GRDB, swift-markdown-ui, etc.) but no user-authored content unless §4.2's `%{private}` discipline was violated upstream. The pre-share preview is the user's last line of defense.

```swift
func exportRecentLogs(windowMinutes: Int = 15) throws -> URL {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let position = store.position(date: Date().addingTimeInterval(-Double(windowMinutes) * 60))
    let entries = try store.getEntries(at: position)
        .compactMap { $0 as? OSLogEntryLog }
        .filter { $0.subsystem == Bundle.main.bundleIdentifier }
        .map { "[\($0.date)] [\($0.category)] \($0.composedMessage)" }
        .joined(separator: "\n")

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("super-logs-\(Date().timeIntervalSince1970).txt")
    try entries.write(to: url, atomically: true, encoding: .utf8)
    return url
}
```

### 4.4 App Store Connect Analytics

Aggregated, anonymous, free, configured via App Store Connect:

- **Trends → Crashes** for crash rate per release.
- **Analytics → Metrics** for installs, sessions, retention, country / device / OS breakdowns.

No SDK or in-app code is required. The data lives in App Store Connect; check it weekly during early SuperBible releases (per [`superpowers/specs/2026-05-23-superbible-fork-design.md`](./superpowers/specs/2026-05-23-superbible-fork-design.md) §4.4).

---

## 5. Server implementation (future)

The SuperOS backend (TypeScript + Hono + Drizzle + Postgres + Redis, per [`SERVER_ARCHITECTURE.md`](./SERVER_ARCHITECTURE.md)) doesn't exist yet. When it does, observability follows the same posture: **platform-native, no third-party aggregators.**

### 5.1 Structured stdout via Pino

```typescript
import pino from "pino";

const logger = pino({
  level: process.env.LOG_LEVEL ?? "info",
  formatters: { level: (label) => ({ level: label }) },
  serializers: { err: pino.stdSerializers.err },
  transport: process.env.NODE_ENV === "development"
    ? { target: "pino-pretty", options: { colorize: true } }
    : undefined,
});

export default logger;
```

In production, logs go to stdout where the hosting platform (Fly.io / Railway / whatever we pick) tails and rotates them. No Datadog, no Logtail, no Better Stack, no Loki, no OpenTelemetry collector.

### 5.2 Correlation IDs in logs

Every request gets an `X-Correlation-ID` (generated client-side, defaulted server-side if absent). Every log line in the request's scope includes it. End-to-end tracing comes from `grep correlation_id=abc-123` across the platform's log tail, not from a distributed-trace UI.

```typescript
app.use("*", async (c, next) => {
  const correlationId = c.req.header("X-Correlation-ID") ?? crypto.randomUUID();
  const start = performance.now();

  c.set("correlationId", correlationId);
  c.header("X-Correlation-ID", correlationId);

  await next();

  logger.info({
    msg: "request_completed",
    method: c.req.method,
    path: c.req.routePath,
    status: c.res.status,
    duration_ms: Math.round(performance.now() - start),
    correlation_id: correlationId,
  });
});
```

### 5.3 Logging conventions

- Always include `correlation_id` in request-scoped logs.
- Log AI tool calls with **parameter keys only**, never values (`param_keys: ["title", "due_date"]` — not `{title: "Buy milk"}`).
- Log errors with structured context: endpoint, model, correlation_id, err.
- Never log message text, verse text, task titles, user identifiers, or anything else that could constitute PII or user content.

### 5.4 Platform-native dashboards

Whichever host we pick (Fly.io / Railway / Render / etc.), use its built-in dashboards for:

- Request count + p50/p95 latency.
- Memory + CPU per instance.
- Process restarts.
- Log tail with `grep`-style filtering.

If those dashboards prove inadequate over time, the right move is usually to write a small custom `/metrics` JSON endpoint and a `Trends.md` weekly-review checklist, **not** to bring in Datadog.

### 5.5 Server thresholds — to be set when the server lands

The earlier draft of this document carried a fully-populated alert-threshold table (request latency p50/p95/p99, error rate, AI time-to-first-token, AI stream duration, DB query latency, connection pool utilization). That table was load-bearing precisely because it set the line between "normal" and "something to look at."

The server doesn't exist yet, so a frozen-in-doc threshold table would be a guess. The TODO at server-build time:

1. Run the new server under realistic load for 1–2 weeks to learn baselines.
2. Add a `docs/SERVER_THRESHOLDS.md` (or a §6 here) capturing concrete numbers: p50 / p95 / p99 per route, error rate per route, AI-call latency by model, DB query latency.
3. Set the weekly-review trigger numbers at p95 + a margin, not at "industry rule-of-thumb" defaults.
4. Until then: the *only* threshold this project commits to is the client crash-free target (`>99.5%`, per [`PRODUCT_VISION.md`](./PRODUCT_VISION.md) §12).

---

## 6. Privacy

### 6.1 Hard rules (project-wide)

These rules apply identically to both apps:

1. **Analytics share toggle is the user's.** We never override it, never gate features on it, never ask for it. App Store Connect respects the device-level toggle automatically.
2. **No PII in any telemetry.** Never logged, never persisted to disk, never transmitted: usernames, email addresses, message content, verse text, task titles, note content, calendar event names, contact info, location, browsing history, plan progress trajectories.
3. **Anonymized identifiers only.** Hashed device IDs at most. We don't even need that.
4. **Parameter keys, not values.** Tool calls log key names; never values.
5. **On-device by default.** Logs stay on the device unless the user explicitly exports them.

### 6.2 App Store privacy nutrition label

Based on the rules above, the declaration for SuperBible (and SuperOS, if it ever ships) is:

| Data type | Collected | Linked to identity | Used for tracking |
|---|---|---|---|
| Crash data | Yes *(via App Store Connect opt-in)* | No | No |
| Performance data | Yes *(via App Store Connect opt-in)* | No | No |
| Diagnostics | Yes *(via App Store Connect opt-in)* | No | No |
| Identifiers | No | — | — |
| Product interaction | No | — | — |
| User content | No | — | — |
| Location | No | — | — |
| Contacts | No | — | — |

SuperBible's `App-SuperBible/PRIVACY.md` restates these in user-facing language.

---

## 7. "Alerting"

There is no real-time alerting. This is a deliberate choice for a solo project:

- App Store Connect emails the maintainer when a new crash signature appears or a crash rate spikes. Async, no SDK, no paging.
- A weekly check-in: App Store Connect Trends + the platform's server-log tail. If something's wrong, it shows up there.
- The crash-free-sessions threshold is `>99.5%` (per [`PRODUCT_VISION.md`](./PRODUCT_VISION.md) §12). Two consecutive weeks below that on a release is the trigger to reconsider whether the Apple-built-in posture is enough.

If the project ever has paying users, on-call rotation, or a team — the conversation changes. Until then, async is fine.

---

## 8. Implementation phases

### Phase 1 — Ship with SuperBible v1 (SB-M0 through SB-M4)

| Component | Effort |
|---|---|
| `MetricKitManager` actor + JSONL persistence | 0.5 day |
| `os_log` Logger categories + audit existing call sites for `%{public}` discipline | 1 day |
| Settings → About → "Export recent diagnostic log" row + share sheet | 0.5 day |
| App Store Connect: confirm Trends + Analytics opt-ins are enabled for both targets | trivial |
| `App-SuperBible/PRIVACY.md` content | 0.5 day |
| **Total** | **~2.5 days** |

### Phase 2 — Server observability (when the server exists)

| Component | Effort |
|---|---|
| Pino + correlation-ID middleware | 0.5 day |
| Logging convention audit on every route | 1 day |
| Hosting platform dashboard bookmarks + weekly-review checklist | 0.5 day |
| **Total** | **~2 days** |

### Phase 3 — None planned

There is no Phase 3. If at any point a concrete operational pain arises that Apple's built-ins or platform-native logs cannot address, raise a GitHub issue describing the specific harm and the smallest-possible mitigation. Most "we should add Sentry" reflexes are better solved by writing better logs, or by sitting with the data App Store Connect already provides.

---

## 9. SuperBible-specific notes

SuperBible inherits everything above. The only extras:

- `App-SuperBible/PRIVACY.md` is the user-facing summary (one-pager — fewer architectural details, more reassurance).
- App Store Connect analytics will be the *only* product-signal channel for SuperBible. There is no analytics SDK. Cohort analysis means "look at retention curves in App Store Connect Analytics."
- The same MetricKit subscriber code runs in both apps; the persistence path differs (per-bundle Application Support directory).

A short SuperBible-only restatement lives at [`SuperBible/OBSERVABILITY.md`](./SuperBible/OBSERVABILITY.md).
