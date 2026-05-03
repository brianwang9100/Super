# Super: Observability

> Full-stack observability strategy covering usage analytics, crash reporting, performance metrics, and logging for iOS/macOS clients and the TypeScript backend.

**Prerequisite reading:** [MOBILE_ARCHITECTURE.md](./MOBILE_ARCHITECTURE.md) for client-side architecture, [SERVER_ARCHITECTURE.md](./SERVER_ARCHITECTURE.md) for backend topology, [PRODUCT_VISION.md](./PRODUCT_VISION.md) for applet descriptions.

> **Status (2026-05-03):** Not wired yet. No analytics SDK, no crash reporter, no metrics pipeline in the binary. Tracked in [`TODO.md`](../TODO.md) § Observability.

---

## 1. Goals

Observability in Super is not just "add logging for debugging." It serves four distinct purposes:

| Goal | What it answers |
|------|----------------|
| **Product analytics** | Which applets are people using? Which features are ignored? Where do users drop off? |
| **Crash visibility** | When the app crashes, what happened? How many users are affected? Is it getting worse? |
| **Performance monitoring** | Is the app fast? Are API calls slow? Which queries are bottlenecks? Is the AI proxy adding latency? |
| **Operational awareness** | Is the server healthy? Are database connections exhausted? Is Redis evicting keys? |
| **Actionable insights** | Every piece of data collected should lead to a decision — fix a bug, cut a feature, optimize a query, or scale a resource. If data doesn't inform action, don't collect it. |

**Non-goals:**
- Surveillance. No tracking of message content, task titles, or personal data.
- Vanity metrics. DAU/MAU is useful; "total API calls" in isolation is not.
- Over-instrumentation that degrades performance or bloats the binary.

---

## 2. Observability Pillars

### 2.1 Metrics

Quantitative measurements sampled or aggregated over time.

**Client-side examples:**
- App launch time (cold and warm)
- Animation frame rate (drops below 60fps)
- GRDB query latency per applet
- Network request latency (p50, p95)
- Memory usage per applet

**Server-side examples:**
- Request latency per endpoint (p50, p95, p99)
- AI proxy latency (time to first token, total stream duration)
- Database query latency
- Error rate per endpoint
- Redis hit/miss ratio

### 2.2 Logs

Structured event records for debugging, auditing, and post-incident analysis.

- Must be structured (JSON or key-value), not free-form strings.
- Must include correlation IDs to tie client actions to server requests.
- Must never contain PII (see [Section 8](#8-privacy-considerations)).
- Must have consistent severity levels: `debug`, `info`, `warning`, `error`, `critical`.

### 2.3 Traces

End-to-end request flow tracking across system boundaries.

A single user action can span multiple components:

```
User types in Chat chat
  → Client sends request to server (correlation ID: abc-123)
    → Server receives, authenticates, routes
      → Server calls LLM API (OpenAI/Anthropic)
        → LLM returns tool call
      → Server executes tool (e.g., create_task in ToDo)
      → Server streams response back
  → Client renders streamed response
  → Client updates ToDo via event bus
```

Traces let you see this entire flow as a single timeline, identifying where time is spent and where failures occur.

### 2.4 Crash Reporting

Capture, symbolicate, group, and alert on application crashes.

- **Capture:** Record the crash with full stack trace, device state, and breadcrumbs of recent user actions.
- **Symbolicate:** Convert memory addresses to human-readable function names (requires dSYM upload).
- **Group:** Cluster identical crashes so you see "1 crash affecting 200 users" not "200 individual crashes."
- **Alert:** Notify when a new crash appears or an existing crash spikes.

---

## 3. Platform Evaluation

### 3.1 Comparison Table

| Capability | Datadog | Sentry | Firebase + Crashlytics | PostHog | Apple Built-in (MetricKit + os_log) |
|---|---|---|---|---|---|
| **iOS crash reporting** | Yes (dd-sdk-ios, RUM) | Yes (excellent) | Yes (Crashlytics, excellent) | Limited | MetricKit crash diagnostics (Xcode only) |
| **macOS crash reporting** | Yes (same SDK) | Yes | **No Crashlytics on macOS** | Limited | MetricKit (macOS 13+) |
| **Node.js/TS APM** | Yes (excellent) | Yes (good) | No | No | No |
| **Product analytics** | Yes (RUM + custom events) | No (not its purpose) | Yes (Google Analytics) | Yes (core strength) | No |
| **Structured logging** | Yes (log management) | Yes (breadcrumbs, limited) | Yes (limited) | No | os_log (on-device only) |
| **Distributed tracing** | Yes (excellent, full APM) | Yes (transactions + spans) | No | No | No |
| **Session replay** | Yes | Yes (beta) | No | Yes | No |
| **Feature flags** | Yes | No | Yes (Remote Config) | Yes | No |
| **Self-hostable** | No | Yes (open source) | No | Yes | N/A |
| **Free tier** | 14-day trial only | 5K errors/mo, 10M transactions/mo | Free (generous) | 1M events/mo (free) | Free |
| **Unified client + server dashboard** | Yes (key differentiator) | Yes (reasonable) | No | No | No |
| **Pricing concern** | Expensive at scale ($23+/host/mo for APM) | Reasonable, scales well | Free | Free self-hosted, paid cloud | Free |
| **Integration effort** | Moderate (comprehensive SDK) | Low (focused SDK) | Low (iOS), N/A (macOS/server) | Low | Minimal (built-in APIs) |

### 3.2 Detailed Platform Notes

**Datadog:**
Datadog's `dd-sdk-ios` provides Real User Monitoring (RUM), crash reporting, logs, and traces for both iOS and macOS from the same SDK. Server-side, Datadog's Node.js APM (`dd-trace`) is mature and well-documented. The unified dashboard — seeing a client crash alongside the server error that caused it — is genuinely valuable. However, Datadog is priced for teams and enterprises. For a solo developer pre-revenue, the cost is hard to justify. It becomes the right choice when Super has paying users and operational complexity demands a single pane of glass.

**Sentry:**
Sentry's crash reporting is best-in-class. The iOS and macOS SDKs are well-maintained (`sentry-cocoa`), and the Node.js SDK integrates cleanly with Hono. Performance monitoring (transactions and spans) provides basic distributed tracing. The free tier (5,000 errors/month, 10 million transactions/month) is more than sufficient for launch. Sentry does not do product analytics — it's an error and performance tool, not a "which features are popular" tool.

**Firebase + Crashlytics:**
Crashlytics is excellent on iOS but **does not support macOS**. Since Super is a universal app targeting both platforms, this is a dealbreaker for unified crash reporting. Google Analytics for Firebase provides basic product analytics but has no server-side equivalent. Not recommended as a primary solution.

**PostHog:**
PostHog excels at product analytics: funnels, retention, feature flags, session replay. The iOS SDK is functional. It can be self-hosted (important for privacy) or used as a cloud service. Crash reporting is not its strength. Best used alongside a dedicated crash reporting tool.

**Apple Built-in (MetricKit + os_log):**
MetricKit (iOS 13+, macOS 13+) provides system-level metrics — hang rate, launch time, battery impact, crash diagnostics — delivered once per day via `MXMetricManager`. `os_log` is Apple's structured logging framework, highly performant, with support for log levels and privacy redaction. Both are free and require no third-party dependencies. The limitation: data is only accessible in Xcode Organizer or App Store Connect. No custom dashboards, no real-time alerting, no server-side equivalent. Essential as a supplement, insufficient alone.

### 3.3 Recommendation

| Layer | Tool | Rationale |
|-------|------|-----------|
| Crash reporting (client + server) | **Sentry** | Best-in-class crash reporting, supports iOS + macOS + Node.js, generous free tier |
| Product analytics | **PostHog** (or custom) | Open-source, self-hostable, iOS SDK, feature flags included |
| System-level performance | **Apple MetricKit** | Free, zero-overhead, provides metrics not available elsewhere (battery, thermals) |
| Structured logging (client) | **os_log** | Apple-native, performant, built-in privacy redaction |
| Structured logging (server) | **Pino** | Fast JSON logger for Node.js, pairs well with any log aggregator |
| Full APM / unified tracing | **Datadog** (future) | Evaluate when scale justifies cost; not needed at launch |

---

## 4. Client-Side Observability (iOS/macOS)

### 4.1 Crash Reporting (Sentry)

**SDK Initialization:**

```swift
import Sentry

// In App.init() or AppDelegate
SentrySDK.start { options in
    options.dsn = "https://examplePublicKey@o0.ingest.sentry.io/0"
    options.tracesSampleRate = 0.2  // 20% of transactions for performance monitoring
    options.profilesSampleRate = 0.1  // 10% for profiling
    options.attachScreenshot = true
    options.enableMetricKit = true  // Forward MetricKit data to Sentry
    options.enablePreWarmedAppStartTracing = true

    #if DEBUG
    options.enabled = false  // Disable in debug builds
    #endif
}
```

**dSYM Upload in CI:**

Symbolication requires uploading debug symbols on every release build. Add to the Xcode Cloud or CI workflow:

```bash
# Using sentry-cli in the post-build step
export SENTRY_ORG="super"
export SENTRY_PROJECT="super-ios"

sentry-cli debug-files upload --include-sources \
  "$DWARF_DSYM_FOLDER_PATH"
```

Alternatively, add the Sentry build phase script to the Xcode project for automatic upload.

**Breadcrumbs:**

Sentry automatically captures breadcrumbs for UI events, network requests, and system events. Add custom breadcrumbs for key user actions:

```swift
import Sentry

// When a user opens an applet
func trackAppletActivation(_ applet: AppletIdentifier) {
    let crumb = Breadcrumb(level: .info, category: "navigation")
    crumb.message = "Activated applet"
    crumb.data = ["applet_id": applet.rawValue]
    SentrySDK.addBreadcrumb(crumb)
}

// When an AI tool call executes
func trackToolExecution(_ toolName: String, appletId: String) {
    let crumb = Breadcrumb(level: .info, category: "ai.tool")
    crumb.message = "Tool executed"
    crumb.data = [
        "tool_name": toolName,
        "applet_id": appletId
    ]
    SentrySDK.addBreadcrumb(crumb)
}
```

**User Context:**

Set anonymized user context so crashes can be grouped per user (without PII):

```swift
let user = Sentry.User()
user.userId = hashedAnonymousId  // SHA-256 of device ID or similar
user.data = [
    "active_applets": activeAppletIds,
    "device_family": deviceFamily,  // "iPhone", "iPad", "Mac"
    "app_version": appVersion
]
SentrySDK.setUser(user)
```

### 4.2 Performance Metrics

**App Launch Time:**

```swift
// MetricKit provides this automatically via MXAppLaunchMetric
// For manual measurement:

class LaunchTimeTracker {
    static let processStart = CFAbsoluteTimeGetCurrent()

    static func markFirstFrameRendered() {
        let launchDuration = CFAbsoluteTimeGetCurrent() - processStart
        let span = SentrySDK.span  // Attach to Sentry transaction if active

        os_log(
            .info,
            log: .performance,
            "App launch completed in %.2f seconds (type: %{public}s)",
            launchDuration,
            launchDuration > 2.0 ? "cold_slow" : "cold_normal"
        )
    }
}
```

**Animation Frame Rate Monitoring:**

```swift
class FrameRateMonitor {
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var droppedFrameCount = 0

    func start() {
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        if lastTimestamp > 0 {
            let frameDuration = link.timestamp - lastTimestamp
            let fps = 1.0 / frameDuration
            if fps < 55 {  // Below threshold
                droppedFrameCount += 1
            }
        }
        lastTimestamp = link.timestamp
    }

    func reportAndReset() -> Int {
        let count = droppedFrameCount
        droppedFrameCount = 0
        return count
    }
}
```

> **Note:** Only enable frame rate monitoring during specific interactions (scrolling, animations), not permanently. Permanent monitoring itself impacts performance.

**GRDB Query Latency:**

```swift
// Wrap GRDB reads/writes with timing
extension DatabaseContainer {
    func timedRead<T>(
        appletId: String,
        label: String,
        _ block: (Database) throws -> T
    ) throws -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try read(block)
        let duration = CFAbsoluteTimeGetCurrent() - start

        if duration > 0.05 {  // Log queries slower than 50ms
            os_log(
                .warning,
                log: .performance,
                "Slow query: %{public}s (applet: %{public}s, duration: %.3fs)",
                label, appletId, duration
            )
        }
        return result
    }
}
```

**Memory Usage Per Applet:**

Track memory before and after applet activation to identify applets with excessive memory footprints:

```swift
func measureAppletMemory(_ appletId: String, during block: () -> Void) {
    let before = reportMemory()
    block()
    let after = reportMemory()
    let delta = after - before

    os_log(
        .info,
        log: .performance,
        "Applet %{public}s memory delta: %{public}d MB",
        appletId, delta / (1024 * 1024)
    )
}

private func reportMemory() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size
    ) / 4
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.resident_size) : 0
}
```

### 4.3 Product Analytics / Usage Tracking

All analytics are **opt-in** and **anonymized**. No PII is ever collected.

**What to track:**

| Event | Properties | Purpose |
|-------|-----------|---------|
| `applet_activated` | `applet_id`, `source` (tab bar, sidebar, deeplink) | Which applets are popular |
| `applet_session_ended` | `applet_id`, `duration_seconds` | How long users spend per applet |
| `ai_chat_message_sent` | `applet_context` (which applet chat was opened from), `message_length_bucket` | AI usage patterns |
| `ai_tool_called` | `tool_name`, `applet_id`, `success` | Which tools are most used |
| `feature_used` | `applet_id`, `feature_name` (e.g., "kanban_view", "list_view") | Feature adoption |
| `applet_installed` | `applet_id` | Applet adoption rate |
| `applet_uninstalled` | `applet_id` | Applet churn |

**Implementation approach (PostHog):**

```swift
import PostHog

// Initialize
let config = PostHogConfig(apiKey: "phc_...", host: "https://app.posthog.com")
PostHogSDK.shared.setup(config)

// Set anonymous ID (no PII)
PostHogSDK.shared.identify(hashedAnonymousId)

// Track events
PostHogSDK.shared.capture(
    "applet_activated",
    properties: [
        "applet_id": "todo",
        "source": "tab_bar"
    ]
)
```

**Privacy controls:**

```swift
// Respect user opt-in preference
if UserDefaults.standard.bool(forKey: "analyticsOptIn") {
    PostHogSDK.shared.optIn()
} else {
    PostHogSDK.shared.optOut()
}
```

### 4.4 Structured Logging

Use Apple's `os_log` as the foundation for all client-side logging.

**Log categories:**

```swift
import os.log

extension OSLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.super"

    static let general    = OSLog(subsystem: subsystem, category: "general")
    static let network    = OSLog(subsystem: subsystem, category: "network")
    static let database   = OSLog(subsystem: subsystem, category: "database")
    static let ai         = OSLog(subsystem: subsystem, category: "ai")
    static let eventBus   = OSLog(subsystem: subsystem, category: "event_bus")
    static let performance = OSLog(subsystem: subsystem, category: "performance")
    static let sync       = OSLog(subsystem: subsystem, category: "sync")
}
```

**Usage patterns:**

```swift
// Network request logging
os_log(
    .info,
    log: .network,
    "API request: %{public}s %{public}s (correlation: %{public}s)",
    method, path, correlationId
)

// Error logging (with private data redacted)
os_log(
    .error,
    log: .database,
    "Query failed: %{public}s (applet: %{public}s, query: %{private}s)",
    error.localizedDescription, appletId, queryDescription
)

// Debug logging (stripped from release builds by the system)
os_log(
    .debug,
    log: .eventBus,
    "Event dispatched: %{public}s → %d subscribers",
    eventType, subscriberCount
)
```

> **Key detail:** `%{private}s` redacts data in release logs. `%{public}s` makes it visible. Default is private. Always use `%{public}s` only for non-sensitive identifiers.

**On-Device Log Export (for bug reports):**

```swift
// Collect recent os_log entries for user-initiated bug reports
func exportRecentLogs() -> String {
    let store = try? OSLogStore(scope: .currentProcessIdentifier)
    let position = store?.position(
        date: Date().addingTimeInterval(-300)  // Last 5 minutes
    )
    let entries = try? store?
        .getEntries(at: position)
        .compactMap { $0 as? OSLogEntryLog }
        .filter { $0.subsystem == Bundle.main.bundleIdentifier }
        .map { "[\($0.date)] [\($0.category)] \($0.composedMessage)" }
        .joined(separator: "\n")
    return entries ?? "Unable to retrieve logs"
}
```

### 4.5 MetricKit Integration

```swift
import MetricKit

class MetricKitManager: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitManager()

    func start() {
        MXMetricManager.shared.add(self)
    }

    // Called once per day with aggregated metrics
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            // Forward key metrics to Sentry or PostHog
            if let launchTime = payload.applicationLaunchMetrics {
                // launchTime.histogrammedTimeToFirstDraw
            }
            if let hangMetrics = payload.applicationResponsivenessMetrics {
                // hangMetrics.histogrammedApplicationHangTime
            }
        }
    }

    // Called when a crash or hang diagnostic is available
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            if let crashDiagnostics = payload.crashDiagnostics {
                // Forward to Sentry as attachments
                for diagnostic in crashDiagnostics {
                    let attachment = Attachment(
                        data: diagnostic.jsonRepresentation(),
                        filename: "metrickit_crash.json",
                        contentType: "application/json"
                    )
                    SentrySDK.capture(message: "MetricKit crash diagnostic") { scope in
                        scope.addAttachment(attachment)
                    }
                }
            }
        }
    }
}
```

---

## 5. Server-Side Observability

### 5.1 APM (Application Performance Monitoring)

**Request latency tracking with Hono middleware:**

```typescript
import { Hono } from "hono";
import * as Sentry from "@sentry/node";
import pino from "pino";

const logger = pino({ level: "info" });

// Middleware: request timing + correlation ID
app.use("*", async (c, next) => {
  const correlationId =
    c.req.header("X-Correlation-ID") ?? crypto.randomUUID();
  const start = performance.now();

  c.set("correlationId", correlationId);
  c.header("X-Correlation-ID", correlationId);

  // Start Sentry transaction
  const transaction = Sentry.startTransaction({
    op: "http.server",
    name: `${c.req.method} ${c.req.routePath}`,
  });
  Sentry.getCurrentHub().configureScope((scope) =>
    scope.setSpan(transaction)
  );

  await next();

  const duration = performance.now() - start;
  transaction.finish();

  logger.info({
    msg: "request_completed",
    method: c.req.method,
    path: c.req.routePath,
    status: c.res.status,
    duration_ms: Math.round(duration),
    correlation_id: correlationId,
  });
});
```

**AI proxy latency (time to first token and total duration):**

```typescript
async function streamFromLLM(
  request: LLMRequest,
  correlationId: string
): AsyncIterable<string> {
  const span = Sentry.startSpan({ op: "ai.llm_call", description: request.model });
  const startTime = performance.now();
  let firstTokenTime: number | null = null;
  let tokenCount = 0;

  try {
    const stream = await llmClient.stream(request);

    for await (const chunk of stream) {
      if (firstTokenTime === null) {
        firstTokenTime = performance.now();
        logger.info({
          msg: "ai_first_token",
          ttft_ms: Math.round(firstTokenTime - startTime),
          model: request.model,
          correlation_id: correlationId,
        });
      }
      tokenCount++;
      yield chunk;
    }
  } finally {
    const totalDuration = performance.now() - startTime;
    logger.info({
      msg: "ai_stream_completed",
      total_ms: Math.round(totalDuration),
      token_count: tokenCount,
      model: request.model,
      correlation_id: correlationId,
    });
    span?.end();
  }
}
```

**Key metrics to track:**

| Metric | Measurement | Alert threshold |
|--------|------------|-----------------|
| Request latency (p50) | Histogram per route | > 200ms |
| Request latency (p95) | Histogram per route | > 1s |
| Request latency (p99) | Histogram per route | > 3s |
| Error rate | Counter per route | > 5% of requests |
| AI time to first token | Histogram per model | > 3s |
| AI total stream duration | Histogram per model | > 30s |
| Database query latency | Histogram | > 100ms |
| Active connections | Gauge | > 80% of pool |

### 5.2 Structured Logging

**Pino configuration:**

```typescript
import pino from "pino";

const logger = pino({
  level: process.env.LOG_LEVEL ?? "info",
  formatters: {
    level(label) {
      return { level: label };
    },
  },
  serializers: {
    err: pino.stdSerializers.err,
  },
  // In production, logs go to stdout for collection by infrastructure
  // In development, pretty-print
  transport:
    process.env.NODE_ENV === "development"
      ? { target: "pino-pretty", options: { colorize: true } }
      : undefined,
});

export default logger;
```

**Logging conventions:**

```typescript
// Always include correlation_id in request-scoped logs
logger.info({ correlation_id, user_id: anonymizedUserId }, "request_received");

// Log AI tool calls with parameter keys only (not values — privacy)
logger.info(
  {
    correlation_id,
    tool_name: "create_task",
    param_keys: ["title", "due_date", "applet_id"],  // Keys only, no values
    applet_id: "todo",
  },
  "ai_tool_call_executed"
);

// Log errors with context
logger.error(
  {
    correlation_id,
    err: error,
    endpoint: "/api/chat",
    model: "claude-sonnet",
  },
  "llm_api_call_failed"
);
```

### 5.3 Infrastructure Metrics

**Postgres connection pool monitoring:**

```typescript
import { Pool } from "pg";

const pool = new Pool({ max: 20 });

// Periodically log pool stats
setInterval(() => {
  logger.info({
    msg: "pg_pool_stats",
    total: pool.totalCount,
    idle: pool.idleCount,
    waiting: pool.waitingCount,
  });
}, 30_000);  // Every 30 seconds
```

**Redis monitoring:**

```typescript
import { Redis } from "ioredis";

const redis = new Redis();

// Periodic Redis stats
setInterval(async () => {
  const info = await redis.info("memory");
  const memoryUsed = parseRedisInfo(info, "used_memory_human");

  const stats = await redis.info("stats");
  const hits = parseRedisInfo(stats, "keyspace_hits");
  const misses = parseRedisInfo(stats, "keyspace_misses");

  logger.info({
    msg: "redis_stats",
    memory_used: memoryUsed,
    hit_rate: hits / (hits + misses),
  });
}, 60_000);  // Every 60 seconds
```

---

## 6. Unified Tracing

### 6.1 Correlation ID Flow

Every user action that crosses system boundaries carries a correlation ID, generated on the client and passed through all layers.

```
┌─────────────────────────────────────────────────────────────────┐
│ Client (iOS/macOS)                                              │
│                                                                 │
│  1. User sends chat message                                     │
│  2. Generate correlationId = UUID()                             │
│  3. POST /api/chat                                              │
│     Header: X-Correlation-ID: abc-123-def                       │
│     Sentry breadcrumb: "chat_message_sent"                      │
│                                                                 │
└─────────────────┬───────────────────────────────────────────────┘
                  │
┌─────────────────▼───────────────────────────────────────────────┐
│ Server (Hono)                                                   │
│                                                                 │
│  4. Middleware extracts X-Correlation-ID: abc-123-def            │
│  5. Sentry transaction started, correlationId set on scope       │
│  6. Log: { correlation_id: "abc-123-def", msg: "chat_request" } │
│  7. Call LLM API                                                │
│     → Sentry span: "ai.llm_call"                               │
│     → Log: { correlation_id, msg: "ai_first_token", ttft: 450 }│
│  8. LLM returns tool call: create_task                          │
│     → Sentry span: "ai.tool_execution"                         │
│     → Log: { correlation_id, tool: "create_task" }              │
│  9. Execute tool → Postgres INSERT                              │
│     → Sentry span: "db.query"                                  │
│ 10. Stream response back to client                              │
│     → Log: { correlation_id, msg: "stream_completed" }          │
│                                                                 │
└─────────────────┬───────────────────────────────────────────────┘
                  │
┌─────────────────▼───────────────────────────────────────────────┐
│ Client (iOS/macOS)                                              │
│                                                                 │
│ 11. Receive streamed response, render in chat UI                │
│ 12. Event bus fires: .taskCreated(id: "task-456")               │
│ 13. ToDo applet refreshes, shows new task                      │
│ 14. Sentry breadcrumb: "tool_result_rendered"                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 6.2 Client-Side Trace Initiation

```swift
func sendChatMessage(_ message: String) async throws {
    let correlationId = UUID().uuidString

    // Start Sentry transaction
    let transaction = SentrySDK.startTransaction(
        name: "ai_chat_message",
        operation: "user_action"
    )
    transaction.setData(value: correlationId, key: "correlation_id")

    // Add breadcrumb
    let crumb = Breadcrumb(level: .info, category: "ai.chat")
    crumb.message = "Chat message sent"
    crumb.data = ["correlation_id": correlationId]
    SentrySDK.addBreadcrumb(crumb)

    // Make API call with correlation ID
    var request = URLRequest(url: chatEndpoint)
    request.setValue(correlationId, forHTTPHeaderField: "X-Correlation-ID")

    // ... send request, handle response ...

    transaction.finish()
}
```

### 6.3 Trace Visualization

With Sentry Performance, traces appear as waterfall timelines showing each span (HTTP request, LLM call, database query, tool execution) with its duration. This makes it immediately visible where time is spent.

When/if migrating to Datadog APM, the same correlation IDs allow Datadog to stitch client and server traces into a single flame graph.

---

## 7. Alerting

### 7.1 What to Alert On

| Condition | Severity | Action |
|-----------|----------|--------|
| New crash type affecting > 1% of sessions | **Critical** | Investigate and hotfix |
| Crash rate increase > 2x from previous day | **Critical** | Check recent deploy, consider rollback |
| API error rate > 5% for 5 minutes | **High** | Investigate server logs |
| API p95 latency > 3s for 10 minutes | **High** | Check database, AI provider |
| AI provider returning 5xx for 2 minutes | **High** | Check provider status page, consider failover |
| Database connection pool > 80% utilized | **Medium** | Monitor, increase pool if persistent |
| Redis memory > 80% of limit | **Medium** | Review eviction policy, check for key leaks |
| Background job failure rate > 10% | **Medium** | Review dead letter queue |

### 7.2 Where Alerts Go

For a solo developer, keep it simple:

| Channel | Use case |
|---------|----------|
| **Email** | All medium and high alerts, daily digest summaries |
| **Slack** (webhook to a `#super-alerts` channel) | Critical and high alerts only, for real-time visibility |
| **Sentry built-in alerts** | Crash spikes, new issue notifications, regression alerts |

Avoid PagerDuty or on-call rotations until there's a team. A solo developer doesn't need to page themselves.

### 7.3 Alert Fatigue Prevention

- **Only alert on actionable conditions.** "CPU at 60%" is not actionable. "CPU at 95% for 10 minutes" is.
- **Group related alerts.** If the AI provider is down, one alert is enough — not one per failed request.
- **Set appropriate thresholds.** Start with generous thresholds and tighten over time as you learn normal baselines.
- **Mute during deploys.** Brief error spikes during deploys are expected; don't alert on them.
- **Weekly review.** If an alert fires regularly but never leads to action, delete it.

---

## 8. Privacy Considerations

### 8.1 Core Principles

1. **Analytics are opt-in.** Users explicitly choose to share usage data. The app works identically with analytics disabled.
2. **No PII in telemetry.** Never log, track, or transmit: usernames, email addresses, message content, task titles, calendar event names, note content, or any user-generated text.
3. **Anonymized identifiers only.** User IDs are hashed. Device IDs are hashed. No way to reverse the hash to identify a person.
4. **Parameter keys, not values.** When logging AI tool calls, log `param_keys: ["title", "due_date"]` — never the actual parameter values.
5. **On-device by default.** `os_log` stays on-device unless the user explicitly exports logs for a bug report.

### 8.2 What IS Collected (When Opted In)

- Crash stack traces (code paths, no user data)
- Performance metrics (timing data, no content)
- Feature usage counts (which applet opened, not what's inside it)
- Device metadata (OS version, device model, app version)
- Anonymized session data (duration, applet switches)

### 8.3 What is NEVER Collected

- Message content (Chat chat messages)
- Task titles or descriptions (ToDo)
- Calendar event names or details (Calendar)
- Note content (Notes)
- Contact names or information
- Location data
- Browsing history or URLs
- Screenshots of user content (Sentry screenshot capture is of the crash moment only and is opt-in)

### 8.4 App Store Privacy Nutrition Labels

Based on the above, Super's App Store privacy label will declare:

| Data type | Collected | Linked to identity | Used for tracking |
|-----------|-----------|-------------------|-------------------|
| Crash data | Yes | No | No |
| Performance data | Yes | No | No |
| Product interaction | Yes (opt-in) | No | No |
| Diagnostics | Yes | No | No |
| Identifiers | No | No | No |
| Usage data | Yes (opt-in) | No | No |

---

## 9. Implementation Phases

### Phase 1: Ship with v1

**Goal:** Know when things break. Minimum viable observability.

| Component | Tool | Effort |
|-----------|------|--------|
| Crash reporting (iOS + macOS) | Sentry (`sentry-cocoa`) | 1 day |
| Crash reporting (server) | Sentry (`@sentry/node`) | 0.5 day |
| dSYM upload in CI | `sentry-cli` | 0.5 day |
| Structured logging (client) | `os_log` with categories | 1 day |
| Structured logging (server) | Pino | 0.5 day |
| Correlation ID middleware | Custom (Hono middleware) | 0.5 day |
| MetricKit integration | `MXMetricManagerSubscriber` | 0.5 day |
| **Total** | | **~4 days** |

### Phase 2: Product Analytics (v1.1–v1.2)

**Goal:** Know what's being used and what's not.

| Component | Tool | Effort |
|-----------|------|--------|
| Product analytics SDK integration | PostHog iOS SDK | 1 day |
| Define and instrument key events | Custom | 2 days |
| Analytics opt-in UI | Custom (Settings screen) | 0.5 day |
| Dashboard setup | PostHog cloud | 1 day |
| **Total** | | **~4.5 days** |

### Phase 3: Full APM (when scale warrants)

**Goal:** End-to-end tracing, unified dashboards, proactive monitoring.

| Component | Tool | Effort |
|-----------|------|--------|
| Evaluate Datadog vs. staying with Sentry Performance | Research | 1 day |
| Server APM integration | Datadog or Sentry Performance | 2 days |
| Client RUM (if Datadog) | `dd-sdk-ios` | 2 days |
| Unified dashboard setup | Datadog or Grafana | 2 days |
| Alerting rules | Platform-specific | 1 day |
| **Total** | | **~8 days** |

**Trigger for Phase 3:** Any of the following:
- Paid users whose experience depends on reliability
- Multiple server instances requiring coordinated monitoring
- AI costs high enough that tracing per-request cost matters
- Debugging production issues takes more than 30 minutes regularly

---

## 10. Open Questions

1. **PostHog vs. custom analytics:** PostHog's iOS SDK adds ~2 MB to the binary. Is it worth it, or should we build a lightweight custom event collector that posts to a simple `/analytics` endpoint on our own server?

2. **Log aggregation in Phase 1:** Pino logs to stdout. In production, where do they go? If deploying to Fly.io or Railway, both provide built-in log tailing — but no search or retention. Do we need a log aggregator (Logtail, Better Stack, Datadog Logs) even in Phase 1?

3. **Sentry Performance vs. standalone traces:** Sentry's free tier includes 10M transactions/month. Is the Sentry Performance UI good enough for trace visualization, or will we outgrow it quickly?

4. **MetricKit crash diagnostics vs. Sentry:** Both capture crashes. MetricKit diagnostics arrive with a delay (up to 24 hours). Should we forward MetricKit diagnostics to Sentry (as shown in Section 4.5) or treat them as separate data sources?

5. **Analytics during TestFlight:** Should analytics be enabled during TestFlight beta testing? Pro: real usage data before launch. Con: beta testers are not representative users.

6. **Server-side product analytics:** The server sees all API calls. Should we derive product analytics from server logs (e.g., counting `/api/chat` calls per user) instead of instrumenting the client? Simpler, but misses offline-only features.

7. **Cost projections:** At what user count does Sentry's free tier run out? At what point does Datadog's cost become justifiable? Need to model this based on expected events-per-user-per-day.

8. **GDPR / data residency:** If Super has EU users, do analytics and crash reports need to be stored in the EU? Sentry and PostHog both offer EU data residency — but it needs to be configured from the start.
