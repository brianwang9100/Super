# Super: Client <-> Server Communication

> How the iOS/macOS client and the TypeScript/Hono backend talk to each other — sync vs REST, API routing, Chat orchestration, and offline behavior.

**Prerequisite reading:** [MOBILE_ARCHITECTURE.md](./MOBILE_ARCHITECTURE.md) for client-side architecture, [SERVER_ARCHITECTURE.md](./SERVER_ARCHITECTURE.md) for backend internals, [AUTH.md](./AUTH.md) for authentication flow.

---

## 1. Overview

Super uses two fundamentally different communication paradigms between client and server, plus a third for a narrow use case:

1. **Sync (GRDB <-> Postgres change sets)** — for data replication across devices. The client is the source of truth; the server is a backup and relay to other devices. Works offline. See [SYNC.md](./SYNC.md) for the full protocol.

2. **REST API** — for actions that require server-side resources. The client sends a request, the server does something the client cannot do on its own (call an LLM, verify credentials, talk to Plaid), and returns a response. Requires connectivity.

3. **SSE (Server-Sent Events)** — for real-time server-to-client streaming. Used exclusively for AI chat token streaming.

The key principle: **data that the user owns lives locally first.** The server never holds data that the client does not also have. The server exists for two reasons: (a) holding secrets the client should not have (LLM API keys, Plaid tokens), and (b) relaying data between devices (sync).

---

## 2. Communication Paradigms Decision Matrix

### 2.1 When to Use Sync

Use sync for **data that needs to exist on multiple devices.** The client writes to its local GRDB database immediately (no network required), then pushes the change set to the server when connectivity is available. Other devices pull the change set on their next sync cycle.

Characteristics:
- Pull-before-push ordering (see [SYNC.md](./SYNC.md) Section 3)
- Eventual consistency across devices
- Full offline support — the user never waits for the network to create, read, update, or delete their data
- Conflict resolution via last-writer-wins with user-surfaced conflicts for destructive cases

### 2.2 When to Use REST

Use REST for **actions that require server resources the client does not have.** The client sends a request and waits for a response. If the network is unavailable, the action either queues (via OfflineQueue for deferrable writes) or fails with a user-facing message.

Characteristics:
- Request/response pattern
- Requires connectivity (except for queued writes)
- Server holds the capability the client lacks (API keys, external service access, compute)

### 2.3 When to Use SSE

Use SSE for **real-time server-to-client streaming.** Currently used only for AI chat token streaming. SSE is unidirectional (server to client), auto-reconnects on network interruption, and works through HTTP/2, HTTP/3, and CDN/proxy setups.

### 2.4 Decision Table

| Use Case | Paradigm | Why |
|----------|----------|-----|
| Todo CRUD | Sync | Data lives locally, server is backup + multi-device |
| Calendar events | Sync | Same |
| AI chat messages | REST + SSE | Needs server API keys, streaming response |
| Conversation history persistence | Sync | Chat history should be on all devices |
| Login/logout | REST | Auth action |
| Plaid data fetch (Money) | REST | Server holds Plaid tokens |
| Financial data caching | Sync | Cache locally for offline viewing |
| Home device control (Home) | Local only (HomeKit) | No server involvement |
| App settings/preferences | Sync | Multi-device |

---

## 3. API Routing Architecture

### 3.1 Single Gateway, Path-Based Routing

The client has a single base URL pointing to the gateway. It never knows (or cares) which microservice handles a request. The gateway routes by path prefix:

```
Base URL: https://api.super.app

/api/ai/*     ->  AI service (chat, streaming, tool validation)
/api/auth/*   ->  Auth service (login, token refresh)
/api/sync/*   ->  Sync service (push/pull change sets)
/api/money/*  ->  Money service (Plaid integration, account data)
```

### 3.2 Client-Side: APIEndpoint Builder

The client constructs requests using an `APIEndpoint` struct. The client code never constructs raw URLs or thinks about which microservice handles what — it just calls builder methods that produce the correct path.

```swift
struct APIEndpoint: Sendable {
    let path: String
    let method: HTTPMethod
    let body: (any Encodable & Sendable)?
    let headers: [String: String]
    let queryParams: [String: String]
    let requiresAuth: Bool
    let timeout: TimeInterval

    // MARK: - AI

    static func aiChatStream(
        messages: [LLMMessage],
        tools: [LLMTool]
    ) -> APIEndpoint {
        APIEndpoint(
            path: "/api/ai/chat/stream",
            method: .post,
            body: ChatRequest(messages: messages, tools: tools),
            headers: ["Accept": "text/event-stream"],
            queryParams: [:],
            requiresAuth: true,
            timeout: 120
        )
    }

    // MARK: - Sync

    static func syncPush(
        applet: String,
        changes: [SyncChange]
    ) -> APIEndpoint {
        APIEndpoint(
            path: "/api/sync/\(applet)/push",
            method: .post,
            body: SyncPushRequest(changes: changes),
            headers: [:],
            queryParams: [:],
            requiresAuth: true,
            timeout: 30
        )
    }

    static func syncPull(
        applet: String,
        since: Date
    ) -> APIEndpoint {
        APIEndpoint(
            path: "/api/sync/\(applet)/pull",
            method: .get,
            body: nil,
            headers: [:],
            queryParams: ["since": since.ISO8601Format()],
            requiresAuth: true,
            timeout: 30
        )
    }

    // MARK: - Auth

    static func login(
        appleIdentityToken: String
    ) -> APIEndpoint {
        APIEndpoint(
            path: "/api/auth/login",
            method: .post,
            body: LoginRequest(identityToken: appleIdentityToken),
            headers: [:],
            queryParams: [:],
            requiresAuth: false,  // login doesn't have a token yet
            timeout: 15
        )
    }

    static func refreshToken(
        refreshToken: String
    ) -> APIEndpoint {
        APIEndpoint(
            path: "/api/auth/refresh",
            method: .post,
            body: RefreshRequest(refreshToken: refreshToken),
            headers: [:],
            queryParams: [:],
            requiresAuth: false,  // refresh uses refresh token, not access token
            timeout: 15
        )
    }

    // MARK: - Money (Money)

    static func plaidLinkToken() -> APIEndpoint {
        APIEndpoint(
            path: "/api/money/plaid/link-token",
            method: .post,
            body: nil,
            headers: [:],
            queryParams: [:],
            requiresAuth: true,
            timeout: 15
        )
    }

    static func plaidSync(
        institutionId: String
    ) -> APIEndpoint {
        APIEndpoint(
            path: "/api/money/plaid/\(institutionId)/sync",
            method: .post,
            body: nil,
            headers: [:],
            queryParams: [:],
            requiresAuth: true,
            timeout: 30
        )
    }
}
```

### 3.3 Server-Side: Gateway Route Mounting

The gateway mounts each service module's routes under its prefix. In v1 (monolith), this is Hono route composition — all modules run in the same process. In a future v2 (microservices), the gateway becomes a reverse proxy that forwards to separate services.

```typescript
// src/gateway/router.ts
import { Hono } from 'hono';
import { authMiddleware } from './middleware/auth';
import { rateLimitMiddleware } from './middleware/rateLimit';
import { loggingMiddleware } from './middleware/logging';
import { aiRoutes } from '../modules/ai/routes';
import { authRoutes } from '../modules/auth/routes';
import { syncRoutes } from '../modules/sync/routes';
import { moneyRoutes } from '../modules/money/routes';

const app = new Hono();

// Global middleware (applied to all routes)
app.use('*', loggingMiddleware());

// Public routes (no auth required)
app.route('/api/auth', authRoutes);

// Protected routes (auth required)
app.use('/api/*', authMiddleware());
app.use('/api/*', rateLimitMiddleware());

// Mount service modules under their prefixes
app.route('/api/ai', aiRoutes);
app.route('/api/sync', syncRoutes);
app.route('/api/money', moneyRoutes);

// Health check (public)
app.get('/health', (c) => c.json({ status: 'ok' }));

export default app;
```

Each module defines its own routes internally:

```typescript
// src/modules/ai/routes.ts
import { Hono } from 'hono';

export const aiRoutes = new Hono();

aiRoutes.post('/chat/stream', handleChatStream);  // -> POST /api/ai/chat/stream
aiRoutes.post('/chat', handleChat);                // -> POST /api/ai/chat
```

```typescript
// src/modules/sync/routes.ts
import { Hono } from 'hono';

export const syncRoutes = new Hono();

syncRoutes.post('/:applet/push', handleSyncPush);  // -> POST /api/sync/:applet/push
syncRoutes.get('/:applet/pull', handleSyncPull);    // -> GET  /api/sync/:applet/pull
```

This design means the client-side `APIEndpoint` builder and server-side route mounting are the only two places that need to agree on paths. Everything else is abstracted.

---

## 4. Chat Orchestration — Local vs Server

This is the most architecturally significant decision in the client-server communication design. When Chat orchestrates actions across applets, where does the work actually happen?

### 4.1 The Full Flow

```
User sends a message in Chat chat
    |
    v
[Client] POST /api/ai/chat/stream
    |  (message + tool definitions)
    v
[Server: AI Proxy]
    |  1. Rate limit check
    |  2. Token budget check
    |  3. Tool validation (only tools from user's active applets)
    |  4. System prompt injection
    |  5. Forward to LLM provider
    v
[LLM Provider (Claude, etc.)]
    |
    |  Response streams back via SSE
    |  Response may include tool calls (e.g., "todo.create")
    v
[Server] streams SSE events to client
    |
    v
[Client receives stream]
    |
    |--- Text tokens: render in chat UI
    |
    |--- Tool call: WHERE DOES THIS EXECUTE?
```

### 4.2 Answer: Tool Execution is LOCAL (Client-Side)

When the LLM response includes a tool call (e.g., `todo.create(title: "Buy groceries")`), the execution happens entirely on the client:

1. The client receives the tool call from the SSE stream
2. The client validates the tool call (tool exists in registry, required params present, param types valid, category check — destructive actions require user confirmation)
3. The client routes to the appropriate applet's `ToolExecutor` by matching the tool name prefix to the applet
4. The applet executes against its **local GRDB database** (e.g., ToDo inserts a new task row)
5. The applet returns a `ToolResult` (success/failure + data + display summary)
6. The client sends the tool result back to the server (POST to continue the conversation), which forwards it to the LLM so it can generate a final response

### 4.3 Why Local, Not Server?

**Local-first principle.** The data lives on device. Creating a todo means writing to ToDo's local GRDB database. If the server executed the tool, the data would exist on the server first and need to be pushed down — inverting the entire local-first architecture.

**No data duplication.** The server would need copies of every applet's database schema and current state to execute tools. That means syncing all data to the server before any tool call could work — defeating the purpose of local-first.

**Faster.** Local tool execution is a GRDB write (~1ms). Server-side execution would add a network round-trip (~100-500ms) on top of the LLM response time the user is already waiting through.

**Simpler.** The server does not need to understand applet schemas, migration state, or business logic. It is a proxy and validator, not an executor.

**Offline partial support.** If the user somehow had a pre-cached LLM response (or a future local model), tool execution would work without any network at all.

### 4.4 Full Orchestration Diagram

```
[User] -> [Chat UI] -> [Server: AI Proxy] -> [LLM Provider]
                                                       |
                                                  tool_call response
                                                       |
                                                       v
                                              [Client receives]
                                                       |
                                                       v
                                            [Local ToolExecutor]
                                                       |
                                                       v
                                                 [GRDB write]
                                                       |
                                                       v
                                        [Result -> Server -> LLM]
                                                       |
                                                       v
                                            [LLM final response]
                                                       |
                                                       v
                                            [Render in chat UI]
```

### 4.5 Cross-Applet Tool Chains

When a single user message triggers tool calls to multiple applets (e.g., "Schedule time to work on my urgent tasks this week" involves both `todo.list` and `calendar.createBatch`), the flow is:

1. LLM returns multiple tool calls (or chains them across turns)
2. **Each tool call executes locally, sequentially, in the order the LLM requested**
3. Each tool result is sent back to the LLM
4. The LLM may issue more tool calls based on the results (e.g., read todos first, then create calendar blocks)
5. Cross-applet data stays independent — the tool executor for Calendar does not read ToDo's database. The LLM bridges the gap by passing data through tool results and subsequent tool calls.

This matches the applet independence constraint: no applet imports another applet, even during tool execution.

---

## 5. Networking Layer (Client-Side)

### 5.1 HTTPClient Protocol

A thin async wrapper around `URLSession`. The protocol exists so tests can substitute a mock.

```swift
protocol HTTPClient: Sendable {
    /// Send a request and decode the response.
    func request<T: Decodable & Sendable>(
        _ endpoint: APIEndpoint,
        responseType: T.Type
    ) async throws -> T

    /// Send a request and return a stream of raw data chunks (for SSE).
    func stream(
        _ endpoint: APIEndpoint
    ) -> AsyncThrowingStream<Data, Error>
}
```

### 5.2 AuthInterceptor Actor

Handles JWT injection into every authenticated request, with transparent token refresh and refresh coalescing (multiple concurrent requests that discover an expired token share a single refresh call, not N refresh calls).

```swift
actor AuthInterceptor {
    private var accessToken: String?
    private var refreshToken: String?
    private var refreshTask: Task<String, Error>?
    private let keychain: KeychainService

    init(keychain: KeychainService) {
        self.keychain = keychain
        self.accessToken = keychain.read(.accessToken)
        self.refreshToken = keychain.read(.refreshToken)
    }

    /// Inject the current access token into the request.
    /// If expired, refresh first (coalescing concurrent attempts).
    func intercept(_ request: URLRequest) async throws -> URLRequest {
        let token = try await validAccessToken()
        var authedRequest = request
        authedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return authedRequest
    }

    private func validAccessToken() async throws -> String {
        if let token = accessToken, !isExpired(token) {
            return token
        }

        // Coalesce: if a refresh is already in flight, wait for it
        if let existingRefresh = refreshTask {
            return try await existingRefresh.value
        }

        // Start a new refresh
        let task = Task<String, Error> {
            guard let refresh = refreshToken else {
                throw SuperError.authExpired
            }
            let endpoint = APIEndpoint.refreshToken(refreshToken: refresh)
            // Direct URLSession call (no interceptor — avoid recursion)
            let response = try await directRequest(endpoint, responseType: TokenResponse.self)
            self.accessToken = response.accessToken
            self.refreshToken = response.refreshToken
            keychain.write(.accessToken, value: response.accessToken)
            keychain.write(.refreshToken, value: response.refreshToken)
            return response.accessToken
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    func clearTokens() {
        accessToken = nil
        refreshToken = nil
        keychain.delete(.accessToken)
        keychain.delete(.refreshToken)
    }

    private func isExpired(_ token: String) -> Bool {
        // Decode JWT, check exp claim with 30s buffer
        guard let payload = JWT.decode(token) else { return true }
        return payload.exp < Date.now.addingTimeInterval(30)
    }
}
```

### 5.3 OfflineQueue Actor

Write operations that fail due to network unavailability queue locally and flush when connectivity returns. The queue is persisted so it survives app restarts.

```swift
actor OfflineQueue {
    private var pending: [QueuedRequest] = []
    private let store: UserDefaults  // Persisted queue

    init() {
        self.store = .standard
        self.pending = loadPersistedQueue()
    }

    func enqueue(_ endpoint: APIEndpoint) {
        pending.append(QueuedRequest(endpoint: endpoint, timestamp: .now))
        persistQueue()
    }

    func flush(via client: HTTPClient) async {
        while let request = pending.first {
            do {
                try await client.request(request.endpoint, responseType: EmptyResponse.self)
                pending.removeFirst()
                persistQueue()
            } catch {
                break  // Stop on first failure, retry later
            }
        }
    }

    var count: Int { pending.count }

    private func persistQueue() {
        // Encode pending requests to UserDefaults
        let data = try? JSONEncoder().encode(pending)
        store.set(data, forKey: "offlineQueue")
    }

    private func loadPersistedQueue() -> [QueuedRequest] {
        guard let data = store.data(forKey: "offlineQueue"),
              let queue = try? JSONDecoder().decode([QueuedRequest].self, from: data) else {
            return []
        }
        return queue
    }
}
```

### 5.4 NetworkMonitor

Wraps `NWPathMonitor` to provide a reactive connectivity signal. When connectivity is restored, triggers the OfflineQueue flush.

```swift
actor NetworkMonitor {
    private let monitor = NWPathMonitor()
    private(set) var isConnected: Bool = true

    func start(offlineQueue: OfflineQueue, httpClient: HTTPClient) {
        monitor.pathUpdateHandler = { [weak self] path in
            Task {
                guard let self else { return }
                let wasDisconnected = await !self.isConnected
                await self.updateStatus(path.status == .satisfied)

                // Flush queue when connectivity restored
                if wasDisconnected && path.status == .satisfied {
                    await offlineQueue.flush(via: httpClient)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "network-monitor"))
    }

    private func updateStatus(_ connected: Bool) {
        isConnected = connected
    }
}
```

---

## 6. SSE Implementation for AI Chat

### 6.1 Client-Side SSE Consumption

```swift
func streamChat(
    messages: [LLMMessage],
    tools: [LLMTool]
) -> AsyncThrowingStream<LLMStreamEvent, Error> {
    let endpoint = APIEndpoint.aiChatStream(messages: messages, tools: tools)

    return AsyncThrowingStream { continuation in
        Task {
            do {
                let dataStream = httpClient.stream(endpoint)
                var buffer = ""

                for try await chunk in dataStream {
                    guard let text = String(data: chunk, encoding: .utf8) else { continue }
                    buffer += text

                    // SSE events are separated by double newlines
                    while let range = buffer.range(of: "\n\n") {
                        let eventText = String(buffer[buffer.startIndex..<range.lowerBound])
                        buffer = String(buffer[range.upperBound...])

                        if let event = SSEParser.parse(eventText) {
                            continuation.yield(event)
                        }
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
```

### 6.2 Why Not WebSocket?

| Concern | SSE | WebSocket |
|---------|-----|-----------|
| Battery | Lower — no persistent bidirectional connection | Higher — must keep connection alive |
| Reconnection | Automatic via `EventSource` / `Last-Event-ID` | Manual — must implement reconnection logic |
| CDN/Proxy | Works through HTTP/2, HTTP/3, any standard proxy | Often blocked or requires special proxy configuration |
| Direction | Server -> client only (sufficient for LLM streaming) | Bidirectional (unnecessary — client sends via POST) |
| Complexity | Simpler — standard HTTP semantics | More complex — upgrade handshake, frame protocol |

The only real-time server-to-client data in Super is the AI chat token stream. SSE handles this perfectly. Other data (todos, calendar, etc.) operates locally and syncs in the background — no server push needed.

---

## 7. Offline Behavior

### 7.1 What Works Offline

Everything that operates against local GRDB:

- All applet CRUD (create/read/update/delete todos, calendar events, etc.)
- Viewing any data the user has locally
- Browsing between applets and screens
- Home device control (HomeKit operates over local network / Bluetooth)
- Reading conversation history (persisted to GRDB)

### 7.2 What Requires Connectivity

- **AI chat** — requires server to proxy LLM API calls
- **Sync** — pushing/pulling change sets to/from server
- **Money data refresh** — server holds Plaid tokens and fetches from Plaid API
- **Login/logout** — auth actions require server

### 7.3 OfflineQueue Behavior

When the network is unavailable and the user performs an action that would normally hit the server:

1. **Sync pushes** — change sets accumulate in the local `syncLog` table. When connectivity returns, the sync engine pushes them. This is handled by the sync engine itself, not the OfflineQueue (see [SYNC.md](./SYNC.md)).

2. **Other write operations** (job scheduling, etc.) — queued in the `OfflineQueue` actor. When `NetworkMonitor` detects connectivity restored, it triggers `OfflineQueue.flush()`.

3. **AI chat** — cannot be queued (it is interactive and real-time). The UI shows a connectivity indicator and disables the send button.

4. **Read-only API calls** — fail immediately with a user-facing "No connection" message. The user can still read local data.

---

## 8. Request Authentication

Every request to the server includes a Bearer token in the `Authorization` header, with two exceptions:
- `POST /api/auth/login` — the user does not have a token yet
- `POST /api/auth/refresh` — uses the refresh token in the request body, not the access token header

The `AuthInterceptor` actor (Section 5.2) handles token injection transparently. When the access token is expired:
1. The interceptor detects expiration (JWT `exp` claim with 30-second buffer)
2. It calls `POST /api/auth/refresh` with the refresh token
3. It stores the new access + refresh tokens in Keychain
4. It retries the original request with the new access token
5. Concurrent requests that discover the same expiration share the single refresh call (coalescing)

If the refresh token is also expired or revoked, the user is redirected to the login screen.

See [AUTH.md](./AUTH.md) for the full authentication flow, token lifecycle, and username/password login.

---

## 9. Error Handling Across the Wire

| Error | Client Behavior |
|-------|----------------|
| **Network unavailable** | Queue in OfflineQueue (for writes). Show connectivity indicator. Local operations continue normally. |
| **Server 5xx** | Retry with exponential backoff (3 attempts: 1s, 2s, 4s). After 3 failures, show error to user. |
| **Server 4xx (validation)** | Show error message from server response body. Do not retry. |
| **Auth expired (401)** | AuthInterceptor silently refreshes the token and retries the original request. If refresh fails, redirect to login. |
| **LLM provider error** | Show error in chat UI with the provider's error message. Offer a "Retry" button. |
| **Tool call failed** | Show explanation in chat UI. The LLM is informed of the failure so it can explain what went wrong to the user. |
| **SSE stream interrupted** | Reconnect automatically. The client tracks the last received event and can resume. |
| **Sync conflict** | Surface via Notifications notification. User can review conflicting versions and choose. See [SYNC.md](./SYNC.md) Section 5. |
| **Rate limited (429)** | Show "Slow down" message. Respect `Retry-After` header. |

---

## 10. Decision Log

| # | Date | Decision | Rationale | Status |
|---|------|----------|-----------|--------|
| ADR-006 | 2026-03-13 | SSE for AI streaming, not WebSocket | Unidirectional, auto-reconnect, CDN-friendly, lower battery impact on mobile. WebSocket is unnecessary since the only real-time server-to-client data is the LLM token stream. | Accepted |
| ADR-007 | 2026-03-13 | Client-side tool execution (default) | Local-first: data lives on device, tool execution writes to local GRDB. Faster (no network round-trip for tool execution). Simpler (server does not need applet schemas). | Accepted |
| ADR-010 | 2026-03-13 | Custom sync over CloudKit | Platform-agnostic; GRDB/SQLite on client, Postgres on backend, custom change-set sync protocol over HTTPS. See [SYNC.md](./SYNC.md). | Accepted |
| ADR-013 | 2026-03-16 | No server-orchestrated tool execution for v1 | Server-orchestrated flow (server routes tool calls to applet service modules, writes to Postgres first, pushes events to client) was considered but rejected. Breaks local-first (requires connectivity for all tool execution), adds round-trip latency, and forces the server to replicate all applet domain logic. Client-only is simpler and sufficient. Reconsider if a use case emerges where the server must be the authority for a tool call before the client can proceed. | Accepted |
