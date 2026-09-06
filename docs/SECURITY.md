# Super: Security Design

> Security architecture for protecting user data, home devices, AI interactions, and the development pipeline across the Super platform.

**Prerequisite reading:** [PRODUCT_VISION.md](./PRODUCT_VISION.md) for goals and applet descriptions, [MOBILE_ARCHITECTURE.md](./MOBILE_ARCHITECTURE.md) for client-side data flow, [SERVER_ARCHITECTURE.md](./SERVER_ARCHITECTURE.md) for backend topology, [CLIENT_SERVER.md](./CLIENT_SERVER.md) for networking and auth interceptor.

> **Status (2026-05-03):** Partially in effect. What's live: BYOK LLM API keys stored in the iOS Keychain (never on device disk in plaintext, never on a server because there is no server). What's not yet built: server-side auth + JWT, encryption-at-rest for synced data, AuthInterceptor token-rotation flow, HomeKit safety guardrails, and the deployment-pipeline hardening. The on-device threat model and BYOK rules below apply today; everything that involves the server applies once it ships.

---

## 1. Threat Model

### Apple model processing boundary (September 2026)

Both apps distinguish `system-default` (Local only) from `private-cloud-compute` (Private Cloud Compute, PCC). Fresh empty stores select local on iOS 26 and PCC on iOS 27+; populated stores keep their choices. The deployment floor remains iOS 26. PCC is cloud inference, not sync: selected conversation context and enabled tool results can leave the device through Apple's Foundation Models framework. Local persistence is not a promise of local processing.

Apple's framework-managed PCC transport is the narrow exception to SuperOS's general backend-proxy policy. It introduces no custom HTTP transport, provider key, account flow, or SuperBible backend. Unavailable models retain their identity; no automatic local-to-cloud or cloud-to-other-provider fallback is permitted. Diagnostics must not include prompts, responses, or tool payloads. PCC release requires approved account/bundle entitlement, signed distribution, and real-device validation; simulator tests do not establish authorization.

### 1.1 Adversaries

| Adversary | Description | Capability |
|-----------|-------------|------------|
| **Network attacker** | On-path attacker (e.g., hostile Wi-Fi). Can intercept, modify, and replay traffic between client and server. | Passive eavesdropping, active MITM if TLS is compromised or misconfigured. |
| **Compromised device** | Attacker with physical access to an unlocked device, or malware running with user-level privileges. | Read app sandbox (if device jailbroken), access Keychain items if device is unlocked, invoke HomeKit APIs. |
| **Malicious app on same device** | Another app on the same iOS/macOS device attempting to access Super data. | Sandboxed by OS. Cannot read Super's container directly, but could attempt IPC abuse, pasteboard snooping, or shared Keychain group access. |
| **Compromised backend** | Attacker who gains access to the server (via exploit, credential theft, or supply chain). | Read/modify PostgreSQL data, access Redis, read environment variables (API keys), impersonate users. |
| **Compromised AI agent in CI** | An AI agent in the CI pipeline that is manipulated (via poisoned context, prompt injection in issues/PRs, or compromised model). | Push malicious code to agent branches, exfiltrate secrets if pipeline isolation is weak, introduce backdoors. |
| **Prompt injection via LLM** | Adversarial content in user input, tool results, or external data that manipulates the LLM into unintended actions. | Bypass system prompt guardrails, invoke tools with malicious parameters, exfiltrate data via crafted tool calls. |
| **Rogue insider** | A developer or operator with legitimate access acting maliciously. | Direct database access, secret access, code changes. Mitigated by audit logs, branch protection, and review requirements. |

### 1.2 Assets

| Asset | Sensitivity | Location |
|-------|-------------|----------|
| **User productivity data** (todos, calendar events) | High | Client SQLite, server PostgreSQL |
| **Home device credentials & state** | Critical | Client only (managed by HomeKit) |
| **AI conversation history** | High | Client SQLite, optionally synced to server |
| **LLM API keys** (Claude, Open Claw) | Critical | Server environment variables only |
| **User auth tokens** (JWT, refresh tokens) | High | Client Keychain, server-issued |
| **Sync payloads** | High | In transit (HTTPS), temporarily in server memory |
| **Signing certificates & CI secrets** | Critical | CI secret store only |
| **User PII** (Apple ID email, name) | Medium | Server PostgreSQL |
| **Home action audit logs** | Medium | Client SQLite |

### 1.3 Attack Surface Diagram

```
                          ┌─────────────────────────────────────────────────────┐
                          │                   ATTACK SURFACE                    │
                          └─────────────────────────────────────────────────────┘

    ┌──────────────────────────────┐           ┌──────────────────────────────┐
    │         CLIENT (iOS/macOS)   │           │          SERVER              │
    │                              │           │                              │
    │  ┌────────┐  ┌────────────┐  │  HTTPS    │  ┌───────────────────────┐   │
    │  │Chat│  │  Home   │  │◄────────► │  │   Hono API (TypeScript)│  │
    │  │(AI)    │  │ (HomeKit)  │  │  (TLS1.3) │  │                       │   │
    │  └───┬────┘  └─────┬──────┘  │           │  │  ┌─────┐  ┌───────┐  │   │
    │      │             │         │           │  │  │Auth  │  │Sync   │  │   │
    │  ┌───┴────┐  ┌─────┴──────┐  │           │  │  │Layer │  │Engine │  │   │
    │  │SQLite  │  │ HomeKit    │  │           │  │  └──┬──┘  └───┬───┘  │   │
    │  │(GRDB)  │  │ Framework  │  │           │  │     │         │      │   │
    │  └────────┘  └────────────┘  │           │  └─────┼─────────┼──────┘   │
    │                              │           │        │         │          │
    │  ┌────────┐  ┌────────────┐  │           │  ┌─────┴─────┐ ┌┴───────┐  │
    │  │ToDo   │  │  Calendar    │  │           │  │PostgreSQL │ │ Redis  │  │
    │  │(Todos) │  │ (Calendar) │  │           │  └───────────┘ └────────┘  │
    │  └───┬────┘  └─────┬──────┘  │           │                            │
    │      │             │         │           │  ┌──────────────────────┐   │
    │  ┌───┴─────────────┴──────┐  │           │  │  LLM Proxy          │   │
    │  │     Keychain           │  │           │  │  (Claude/Open Claw)  │──────► LLM Provider APIs
    │  │  (tokens, keys)        │  │           │  └──────────────────────┘   │
    │  └────────────────────────┘  │           └──────────────────────────────┘
    └──────────────────────────────┘
                                               ┌──────────────────────────────┐
                                               │     CI/CD PIPELINE           │
                                               │                              │
                                               │  ┌──────────┐ ┌──────────┐  │
                                               │  │AI Agents │ │Build/Sign│  │
                                               │  │(PRs)     │ │Pipeline  │  │
                                               │  └──────────┘ └──────────┘  │
                                               │                              │
                                               │  ┌──────────────────────┐   │
                                               │  │ Secret Store         │   │
                                               │  │ (certs, API keys)    │   │
                                               │  └──────────────────────┘   │
                                               └──────────────────────────────┘

    Attack vectors:
    ─── Network interception (HTTPS ↔ endpoints)
    ─── Prompt injection (user input → LLM → tool calls)
    ─── CI agent manipulation (poisoned PR context → malicious code)
    ─── Device compromise (physical access → SQLite, Keychain)
    ─── Server breach (DB access, secret exfiltration)
```

---

## 2. Encryption

### 2.1 Data at Rest (Client)

#### 2.1.1 iOS/macOS Data Protection (Baseline)

All files in the app sandbox are protected by Apple's Data Protection framework. We set the highest protection class on all database files:

```swift
// Applied to every GRDB DatabasePool on creation
try FileManager.default.setAttributes(
    [.protectionKey: FileProtectionType.complete],
    ofItemAtPath: databasePath
)
```

`NSFileProtectionComplete` ensures files are encrypted with a key derived from the user's passcode and the device's hardware key. Files are inaccessible when the device is locked.

**Limitation:** Data Protection is transparent to the app when unlocked. A compromised app running while the device is unlocked can read the SQLite files directly.

#### 2.1.2 SQLCipher (Full Database Encryption)

GRDB supports SQLCipher via the `GRDB/SQLCipher` SPM variant, providing AES-256 encryption of the entire `.sqlite` file. The database is unreadable without the encryption key, even if the raw file is extracted.

**Key management approach:**

```swift
// 1. On first launch, generate a random 256-bit database key
let dbKey = SymmetricKey(size: .bits256)

// 2. Store the key in Keychain with Secure Enclave protection (if available)
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.super.\(applet.id).dbkey",
    kSecAttrAccessControl as String: SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .privateKeyUsage,  // Requires Secure Enclave on supported devices
        nil
    )!,
    kSecValueData as String: dbKey.rawRepresentation
]

// 3. Open GRDB database with SQLCipher
var config = Configuration()
config.prepareDatabase { db in
    try db.usePassphrase(dbKey.base64EncodedString())
}
let dbPool = try DatabasePool(path: databasePath, configuration: config)
```

**Evaluation — SQLCipher vs. OS-level protection only:**

| Factor | OS-Level Only | SQLCipher |
|--------|--------------|-----------|
| Protection when device locked | Encrypted (Complete protection) | Encrypted |
| Protection when device unlocked | **Unencrypted** (transparent to app) | **Encrypted** (requires key in memory) |
| Protection against file extraction (jailbreak) | Weak (decrypted if device is unlocked) | Strong (file is always encrypted on disk) |
| Performance overhead | None | ~5-15% on writes, ~5% on reads |
| Complexity | None | Key management, migration path |
| Backup implications | Encrypted in iCloud backup | Double-encrypted |

#### 2.1.3 Recommendation

| Applet | Encryption Level | Rationale |
|--------|-----------------|-----------|
| **Home** | SQLCipher + Data Protection | Controls physical security devices. Highest sensitivity. |
| **Chat** | SQLCipher + Data Protection | Conversation history may contain sensitive information shared with the AI. |
| **ToDo** | Data Protection only | Todo data is sensitive but lower risk. OS-level encryption is sufficient. |
| **Calendar** | Data Protection only | Calendar data is sensitive but lower risk. OS-level encryption is sufficient. |

Users can opt into SQLCipher for all applets via a "Full Encryption" toggle in settings. This enables SQLCipher for ToDo and Calendar as well.

#### 2.1.4 Keychain Usage

All secrets stored in Keychain with appropriate protection classes:

| Item | Keychain Class | Access Control |
|------|---------------|----------------|
| Refresh token | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | None (available when unlocked) |
| SQLCipher DB keys | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | `.privateKeyUsage` (Secure Enclave) |
| Biometric unlock token | `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` | `.biometryCurrentSet` |

**Important:** All Keychain items use `ThisDeviceOnly` variants to prevent syncing via iCloud Keychain. Database encryption keys must never leave the device.

### 2.2 Data at Rest (Server)

| Layer | Mechanism | Notes |
|-------|-----------|-------|
| **Disk** | Full-disk encryption on the host (LUKS on Linux, FileVault on macOS dev) | Protects against physical theft of server hardware. |
| **PostgreSQL** | Full-disk encryption covers DB files. No TDE in v1. | PostgreSQL TDE (community or enterprise) is immature. Reassess when stable. |
| **Sensitive columns** | Application-level encryption for home device tokens (if any ever reach server) | Use `aes-256-gcm` with a server-managed key stored in a secret manager (not in env vars). |
| **Redis** | In-memory only, volatile. Configure `requirepass` and TLS. | No persistent data in Redis. Used for rate limiting, session caches, pub/sub. |
| **Backups** | Encrypted backups (GPG or cloud-provider KMS) | Backup encryption key stored separately from backup storage. |

### 2.3 Data in Transit

#### 2.3.1 TLS Configuration

All client-server communication uses HTTPS with TLS 1.3.

```typescript
// Hono server TLS configuration (via reverse proxy, e.g., Caddy or nginx)
// Minimum TLS version: 1.3
// Cipher suites: TLS_AES_256_GCM_SHA384, TLS_CHACHA20_POLY1305_SHA256
// HSTS: max-age=63072000; includeSubDomains; preload
```

#### 2.3.2 Certificate Pinning

**Evaluation:**

| Pro | Con |
|-----|-----|
| Prevents MITM even if a CA is compromised or a rogue cert is issued | Complicates certificate rotation (app update required) |
| Detects corporate TLS inspection proxies | Can brick the app if pin expires and user hasn't updated |
| Standard practice for banking/high-security apps | Adds maintenance burden for a solo/small team |

**Recommendation:** Do not implement certificate pinning in v1. The risk of bricking the app for users outweighs the MITM protection, given that:

1. We use TLS 1.3 exclusively.
2. iOS App Transport Security (ATS) already enforces strong TLS.
3. CA compromise is a low-probability event.

Revisit if Super handles financial data or if the threat model changes.

#### 2.3.3 Sync Payload Security

Sync payloads are encrypted at the transport layer (HTTPS). Application-layer encryption is not applied in v1.

```
Client                          Server
  │                               │
  │  POST /sync/changeset         │
  │  Authorization: Bearer <JWT>  │
  │  Body: { changes: [...] }     │
  │──────────── TLS 1.3 ─────────►│
  │                               │  ← Server can read payload
  │                               │     (needed for conflict resolution)
  │  200 OK                       │
  │  Body: { resolved: [...] }    │
  │◄──────────── TLS 1.3 ─────────│
  │                               │
```

#### 2.3.4 LLM API Calls

Backend-to-LLM-provider communication uses HTTPS. API keys are sent in the `Authorization` header over TLS, never logged, and never included in error responses.

### 2.4 End-to-End Encryption (E2EE) for Sync

E2EE would make the server zero-knowledge: it stores encrypted blobs it cannot read.

**Architecture if adopted:**

```
Client                              Server
  │                                   │
  │  1. Derive key from passphrase    │
  │     or device-bound key           │
  │                                   │
  │  2. Encrypt changeset with key    │
  │     AES-256-GCM(changeset, key)   │
  │                                   │
  │  POST /sync/changeset             │
  │  Body: { encrypted: <blob> }      │
  │──────────────────────────────────►│
  │                                   │  ← Server stores opaque blob
  │                                   │     Cannot read, index, or
  │                                   │     resolve conflicts
  │  200 OK                           │
  │◄──────────────────────────────────│
  │                                   │
  │  3. Decrypt on other device       │
  │     using same key                │
  │                                   │
```

**Trade-offs:**

| Benefit | Cost |
|---------|------|
| Server breach does not expose user data | Server-side conflict resolution is impossible (must use CRDTs or last-write-wins) |
| Regulatory advantage (GDPR, privacy) | Server-side search/indexing is impossible |
| User trust | Key loss = data loss (no recovery unless escrow) |
| | Multi-device key sync is complex |

**Recommendation:** Start without E2EE in v1. Server-side conflict resolution is essential for a reliable sync experience with a small team. Plan E2EE as an opt-in feature in a future release, initially for Chat conversations (highest sensitivity). When implemented, use a passphrase-derived key (PBKDF2/Argon2) with a recovery code mechanism.

---

## 3. Authentication & Authorization

### 3.1 Authentication Flow

See [AUTH.md](./AUTH.md) for the full username/password authentication flow diagram.

```
┌────────┐                          ┌────────┐
│ Client │                          │ Server │
└───┬────┘                          └───┬────┘
    │                                   │
    │  1. POST /auth/login              │
    │     { username, password }        │
    │─────────────────────────────────►│
    │                                   │  2. Verify credentials
    │                                   │     (bcrypt hash check)
    │  3. { accessToken, refreshToken } │
    │◄─────────────────────────────────│
    │                                   │
    │  4. Store refresh token           │
    │     in Keychain                   │
    │  5. Hold access token             │
    │     in memory only                │
    │                                   │
```

### 3.2 Token Design

| Token | Type | Lifetime | Storage | Rotation |
|-------|------|----------|---------|----------|
| **Access token** | JWT (signed, not encrypted) | 15 minutes | In-memory only | Reissued on refresh |
| **Refresh token** | Opaque (random 256-bit, stored hashed in DB) | 30 days | Client Keychain | Rotated on every use (old token invalidated) |

**Access token claims:**

```json
{
  "sub": "user_uuid",
  "iat": 1700000000,
  "exp": 1700000900,
  "iss": "super-api",
  "aud": "super-client"
}
```

**Refresh token rotation:** Each time the client uses a refresh token, the server issues a new refresh token and invalidates the old one. If an old (already-rotated) refresh token is presented, it indicates token theft — the server invalidates all refresh tokens for that user, forcing re-authentication.

### 3.3 Biometric Unlock

Optional Face ID / Touch ID gate on app launch. This does not replace server authentication; it prevents casual access to the app on an unlocked device.

```swift
let context = LAContext()
context.evaluatePolicy(
    .deviceOwnerAuthenticationWithBiometrics,
    localizedReason: "Unlock Super"
) { success, error in
    if success {
        // Retrieve access credentials from Keychain
        // (Keychain item protected with .biometryCurrentSet)
    }
}
```

**Behavior:** Biometric unlock is optional and configurable per user. When enabled, the app shows a blurred overlay on launch until biometric authentication succeeds. Fallback to device passcode if biometric fails.

### 3.4 Backend Authorization

Every database query is scoped to the authenticated user:

```typescript
// Middleware: extract user ID from verified JWT
app.use('/api/*', async (c, next) => {
  const payload = await verifyJWT(c.req.header('Authorization'));
  c.set('userId', payload.sub);
  await next();
});

// Every query includes user scoping — no exceptions
const todos = await db
  .select()
  .from(todosTable)
  .where(eq(todosTable.userId, c.get('userId')));
```

**Rules:**

1. No endpoint returns data without authentication (except `/auth/login` and `/health`).
2. Every DB query includes a `WHERE user_id = ?` clause. No admin endpoints bypass this in v1.
3. No shared/collaborative data in v1. Each user's data is fully isolated.

---

## 4. API & Third-Party Integration Security

### 4.0 Third-Party API Policy

**Principle: Avoid external API integrations unless they are essential to an applet's core function.** Every third-party API is an attack surface, a privacy risk, and a dependency that can break or change terms.

When a third-party API is required:

1. **Bring Your Own Key (BYOK).** Super is open source. We never ship API keys. Users (developers) provide their own API keys for every external service (Claude, Open Claw, Plaid, etc.).
2. **Key entry during applet onboarding.** When a user enables an applet that requires an API key, the applet's setup flow prompts for the key as part of onboarding. The applet cannot be activated without it.
3. **Keys stored in Keychain (client) or encrypted columns (server).** Never in UserDefaults, plaintext, or committed to source.
4. **Keys scoped to minimum permissions.** Documentation should guide users to create API keys with the narrowest possible scope (e.g., read-only for Plaid).
5. **Graceful degradation.** If an API key is missing, invalid, or revoked, the applet should clearly communicate the issue and guide the user to re-enter credentials — never crash or silently fail.

| Applet | Required API Key | Where Stored | Scope |
|--------|-----------------|--------------|-------|
| Chat | Claude / Open Claw API key | Server (encrypted column) | Chat + tool use |
| Money | Plaid API key + secret | Server (encrypted column) | Read-only financial data |
| Home | None (HomeKit is local) | N/A | N/A |
| ToDo | None | N/A | N/A |
| Calendar | None (EventKit is local) | N/A | N/A |

### 4.1 Rate Limiting

Rate limits are enforced per user (by `userId` from JWT) using a Redis-backed sliding window:

| Endpoint Category | Limit | Window | Rationale |
|-------------------|-------|--------|-----------|
| **AI chat** (`/api/chat/*`) | 60 requests | 1 hour | Most expensive (LLM token costs) |
| **Sync** (`/api/sync/*`) | 120 requests | 1 minute | Prevent sync storms |
| **Auth** (`/api/auth/*`) | 10 requests | 1 minute | Brute-force prevention |
| **General API** (`/api/*`) | 300 requests | 1 minute | General abuse prevention |

Responses include standard rate limit headers:

```
X-RateLimit-Limit: 60
X-RateLimit-Remaining: 45
X-RateLimit-Reset: 1700001000
Retry-After: 120
```

### 4.2 Request Validation

All request bodies are validated with Zod schemas before processing:

```typescript
import { z } from 'zod';
import { zValidator } from '@hono/zod-validator';

const createTodoSchema = z.object({
  title: z.string().min(1).max(500),
  dueDate: z.string().datetime().optional(),
  priority: z.enum(['none', 'low', 'medium', 'high']).default('none'),
  // No userId field — always from JWT, never from client
});

app.post('/api/todos',
  authMiddleware,
  zValidator('json', createTodoSchema),
  async (c) => { /* ... */ }
);
```

**Rules:**

1. Every endpoint has a Zod schema. No `any` types in request handling.
2. `userId` is never accepted from the client. Always extracted from JWT.
3. String fields have maximum lengths to prevent oversized payloads.
4. Array fields have maximum item counts.

### 4.3 Response Headers

Applied globally via middleware:

```typescript
app.use('*', async (c, next) => {
  await next();
  c.header('Strict-Transport-Security', 'max-age=63072000; includeSubDomains; preload');
  c.header('X-Content-Type-Options', 'nosniff');
  c.header('X-Frame-Options', 'DENY');
  c.header('X-XSS-Protection', '0'); // Disabled in favor of CSP
  c.header('Referrer-Policy', 'strict-origin-when-cross-origin');
  c.header('Content-Security-Policy', "default-src 'none'; frame-ancestors 'none'");
});
```

### 4.4 CORS

No web client in v1. CORS is set to deny all origins:

```typescript
app.use('*', cors({
  origin: [],  // No allowed origins
  allowMethods: [],
}));
```

If a web client is added later, CORS must be restricted to the exact production domain. Never use `origin: '*'`.

### 4.5 Input Sanitization

- All text inputs are validated for length and character constraints via Zod.
- SQL injection is prevented by GRDB (client) and Drizzle/parameterized queries (server). Raw SQL strings are never constructed from user input.
- No HTML rendering of user content, so XSS is not a direct risk. If ever added, use a strict allowlist sanitizer.

### 4.6 API Versioning

API version is included in the URL path: `/api/v1/...`. When breaking changes are needed, a new version is introduced. Old versions are supported for a minimum of 6 months after deprecation notice, with the client prompted to update.

---

## 5. AI/LLM Security

### 5.1 API Key Protection

LLM API keys (Claude, Open Claw) are stored exclusively on the server:

```
Client ──► Super Server ──► Claude API
              │                     │
              │  API key lives      │
              │  here only          │
              │  (env var /         │
              │   secret manager)   │
```

The client never knows the API key. The server acts as a proxy, forwarding chat requests and streaming responses.

### 5.2 Prompt Injection Defense

**Layered defense model:**

```
┌───────────────────────────────────────────────────────────┐
│ Layer 1: System Prompt (server-controlled)                │
│   - Defines allowed behavior and tool set                 │
│   - Not modifiable by client                              │
│   - Includes instruction boundary markers                 │
├───────────────────────────────────────────────────────────┤
│ Layer 2: Input Validation                                 │
│   - User message length limits                            │
│   - No raw system-prompt-level messages from client       │
│   - Client sends role: "user" messages only               │
├───────────────────────────────────────────────────────────┤
│ Layer 3: Tool Call Validation (server-side)                │
│   - Tool name must be in the allowed set for this applet  │
│   - Tool parameters are type-checked with Zod schemas     │
│   - Numeric parameters are range-validated                │
│   - String parameters are length-limited                  │
├───────────────────────────────────────────────────────────┤
│ Layer 4: Output Validation (client-side)                  │
│   - Tool calls in AI responses are validated before exec  │
│   - Unknown tool names are rejected                       │
│   - Destructive actions require user confirmation (§6)    │
└───────────────────────────────────────────────────────────┘
```

**Specific measures:**

1. The system prompt is defined server-side and injected into every conversation. The client cannot override or append to the system prompt.
2. Tool definitions are registered per applet. The LLM can only call tools that the active applet has declared. A tool call for `unlock_front_door` is only valid if Home is active and has registered that tool.
3. Every tool call parameter is validated against a Zod schema before execution. Example:

```typescript
const setThermostatSchema = z.object({
  temperature: z.number().min(50).max(90),  // Fahrenheit, reasonable range
  mode: z.enum(['heat', 'cool', 'auto', 'off']),
});
```

4. The AI cannot execute arbitrary code, make arbitrary HTTP requests, or access the filesystem.

### 5.3 Token Budget Enforcement

Per-user token limits prevent cost runaway from excessive AI usage or prompt injection attacks that attempt to generate large outputs:

| Limit | Value | Enforcement |
|-------|-------|-------------|
| **Per-request input** | 32,000 tokens max | Server rejects oversized requests |
| **Per-request output** | 8,000 tokens max | Server sets `max_tokens` on LLM call |
| **Daily per-user** | 200,000 tokens | Server tracks usage in Redis, returns 429 when exceeded |
| **Monthly per-user** | 2,000,000 tokens | Server tracks usage in PostgreSQL |

### 5.4 Conversation Data Handling

- Conversations are stored in the Chat SQLite database on the client (encrypted with SQLCipher, per Section 2.1.3).
- If sync is enabled for conversations, they are treated as highest-sensitivity data.
- Conversations are never logged on the server beyond what is needed for the LLM proxy call. The server does not persist conversation history.
- LLM provider data retention policies are documented for users (e.g., Claude's data usage policy).

---

## 6. Home Automation Security (Home)

### 6.1 HomeKit Security Model

Home delegates all device authentication and communication to Apple's HomeKit framework. Super never directly communicates with home devices or manages device credentials.

```
Super (Home)
    │
    │  HomeKit Framework API
    ▼
┌──────────────┐
│   HomeKit    │  ← Apple manages: device pairing, authentication,
│   Daemon     │     encrypted communication, access control
└──────┬───────┘
       │  Encrypted (HAP protocol)
       ▼
┌──────────────┐
│  Home Device │  (lock, thermostat, camera, etc.)
└──────────────┘
```

**This means:**

- No device credentials are stored in Super's data.
- No device credentials ever reach the Super server.
- Device communication is encrypted by HomeKit (HAP — HomeKit Accessory Protocol).
- Multi-user access control is managed by HomeKit's home sharing.

### 6.2 Destructive Action Confirmation

Any action on a security-sensitive device initiated by the AI requires explicit user confirmation:

```swift
enum HomeActionSensitivity {
    case routine    // lights, thermostat adjustments
    case sensitive  // locks, garage doors, security systems, cameras
}

// Security-sensitive devices require biometric or explicit tap confirmation
func executeHomeAction(_ action: HomeAction) async throws {
    if action.sensitivity == .sensitive {
        let confirmed = await requestUserConfirmation(
            title: "Confirm Home Action",
            message: "\(action.source.displayName) wants to \(action.description)",
            requireBiometric: true  // Face ID / Touch ID
        )
        guard confirmed else { throw HomeActionError.userDenied }
    }
    try await homeKitService.execute(action)
    auditLog.record(action)
}
```

**Classification:**

| Device Type | Sensitivity | Confirmation Required |
|-------------|------------|----------------------|
| Lights | Routine | No |
| Thermostat | Routine | No |
| Locks | **Sensitive** | Biometric |
| Garage doors | **Sensitive** | Biometric |
| Security systems | **Sensitive** | Biometric |
| Cameras | **Sensitive** | Biometric |
| Outlets / switches | Routine | No |

### 6.3 Action Audit Log

All home actions are logged in a local SQLite table:

```sql
CREATE TABLE homeActionLog (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp   TEXT NOT NULL,       -- ISO 8601
    source      TEXT NOT NULL,       -- 'user' | 'ai' | 'automation'
    deviceId    TEXT NOT NULL,       -- HomeKit device identifier
    deviceName  TEXT NOT NULL,
    action      TEXT NOT NULL,       -- 'lock' | 'unlock' | 'set_temperature' | ...
    parameters  TEXT,                -- JSON, e.g., {"temperature": 72}
    result      TEXT NOT NULL,       -- 'success' | 'failed' | 'denied'
    error       TEXT                 -- Error description if failed
);
```

The audit log is queryable by the user in Home settings. Logs are retained for 90 days locally.

### 6.4 Rate Limiting Home Actions

AI-initiated home commands are rate-limited to prevent rapid-fire toggling:

| Limit | Value |
|-------|-------|
| Same device, same action | Max 3 times per minute |
| Total AI-initiated actions | Max 20 per minute |
| Sensitive device actions | Max 1 per 30 seconds |

If a rate limit is hit, the action is rejected and the AI is informed via a tool response error.

---

## 6.5 Financial Data Security (Money — Future)

Money handles the most sensitive data category in Super: financial credentials and transaction history. These rules apply when Money is implemented.

### 6.5.1 Plaid Integration Security

- **Plaid tokens are server-side only.** The client never sees, stores, or transmits Plaid access tokens. The backend holds them in encrypted database columns.
- **Plaid Link flow:** The client uses Plaid Link (embedded WebView) to authenticate with banks. Plaid Link returns a `public_token` to the client, which is immediately exchanged for an `access_token` via the backend. The `public_token` is single-use and short-lived.
- **Token rotation:** Plaid supports access token rotation. The backend should rotate tokens periodically and on any suspected compromise.
- **Webhook security:** Plaid sends transaction updates via webhooks. The backend must verify webhook signatures using Plaid's verification key to prevent spoofed webhook attacks.

### 6.5.2 Financial Data Handling

- **Transaction data on client:** Transaction data synced to the client is less sensitive than credentials (it's read-only account history), but still personal. It should be encrypted at rest (SQLCipher recommended for Money's database).
- **No account numbers in logs:** Account numbers, routing numbers, and balances must never appear in logs, metrics, or crash reports. Log only anonymized account identifiers.
- **AI access to financial data:** Chat can query transactions and balances via tools (e.g., `money.get_balance`, `money.search_transactions`). Tool results sent to the LLM should summarize, not dump raw account numbers. The AI should never see full account/routing numbers.
- **Data retention:** Users can disconnect a bank account at any time. Disconnecting must delete the Plaid token server-side and offer to delete transaction history client-side.

### 6.5.3 Regulatory Considerations

- Plaid handles PCI compliance for payment card data
- Super does not store raw card numbers — Plaid provides masked numbers only
- Privacy policy must disclose financial data collection and Plaid's role as a data processor
- Consider SOC 2 compliance for the backend if Money reaches production

---

## 7. CI/CD Security (AI Agents)

### 7.1 Threat: AI Agents with Write Access

AI agents in the CI pipeline can autonomously create branches and submit PRs. This is a significant attack surface: a compromised or manipulated agent could introduce backdoors, exfiltrate secrets, or modify security-critical code.

### 7.2 Branch Protection

```
main (protected)
  │
  ├── Protected: requires 1 human approval, no direct push
  │
  ├── agent/* (agent branches)
  │     │
  │     ├── AI agents can ONLY push to agent/* branches
  │     ├── PRs from agent/* → main require human review
  │     └── No force push allowed
  │
  └── dev/* (developer branches)
        │
        └── Human developers' feature branches
```

**Rules enforced at the repository level:**

1. `main` branch: no direct pushes, requires at least 1 human approval on PRs.
2. AI agents are granted a deploy key or fine-grained PAT that can only push to `agent/*` branches.
3. No force pushes to any protected branch.

### 7.3 Secrets Isolation

```
┌─────────────────────────────────────────────┐
│              CI Pipeline                     │
│                                              │
│  ┌──────────────────┐  ┌─────────────────┐  │
│  │  Agent Step      │  │  Build/Sign Step │  │
│  │                  │  │                  │  │
│  │  - Reads issue   │  │  - Signing certs │  │
│  │  - Writes code   │  │  - API keys      │  │
│  │  - Pushes branch │  │  - Deploy tokens │  │
│  │                  │  │                  │  │
│  │  NO access to:   │  │  Has access to:  │  │
│  │  signing certs,  │  │  all secrets     │  │
│  │  API keys,       │  │  needed for      │  │
│  │  deploy tokens   │  │  build & deploy  │  │
│  └──────────────────┘  └─────────────────┘  │
│                                              │
│  Secrets are scoped to specific pipeline     │
│  steps. Agent steps have minimal secrets.    │
└─────────────────────────────────────────────┘
```

The agent step receives only:

- A repository token scoped to `agent/*` branches (read/write).
- An LLM API key for the agent's own reasoning (distinct from production keys, with tight spending limits).

The agent step does NOT receive:

- Code signing certificates.
- Production API keys.
- Deployment credentials.
- Database connection strings.

### 7.4 Automated Scanning

| Tool | Purpose | Trigger |
|------|---------|---------|
| **Dependabot / Renovate** | Dependency vulnerability scanning | Scheduled + on PR |
| **CodeQL** | Static analysis for security vulnerabilities | On every PR |
| **Secret scanning** | Detect accidentally committed secrets | On every push |
| **License compliance** | Verify dependency licenses | On PR |
| **SAST** | Swift and TypeScript security patterns | On every PR |

All scanning results are required to pass before a PR can be merged. Security-critical findings block merge.

### 7.5 Supply Chain Security

1. **Lockfiles:** `Package.resolved` (Swift) and `pnpm-lock.yaml` (TypeScript) are committed and verified.
2. **Dependency pinning:** Major version changes require human review. Minor/patch updates are auto-merged only after CI passes.
3. **Checksum verification:** SPM and pnpm verify package checksums against the lockfile.
4. **Minimal dependencies:** Prefer standard library and first-party (Apple) frameworks over third-party dependencies where possible.

---

## 8. Sync Security

### 8.1 Sync Protocol Security

```
Client                                    Server
  │                                         │
  │  POST /api/v1/sync/push                 │
  │  Authorization: Bearer <access_token>   │
  │  Content-Type: application/json         │
  │  Body: {                                │
  │    appletId: "todo",                   │
  │    lastSyncTimestamp: "...",             │
  │    changes: [                           │
  │      { table, rowId, operation, data }  │
  │    ]                                    │
  │  }                                      │
  │────────────────────────────────────────►│
  │                                         │
  │                                         │  1. Verify JWT
  │                                         │  2. Validate payload (Zod)
  │                                         │  3. Verify all changes belong
  │                                         │     to authenticated user
  │                                         │  4. Apply changes with
  │                                         │     conflict resolution
  │                                         │  5. Return resolved state
  │                                         │
  │  200 OK                                 │
  │  Body: { resolved: [...],               │
  │          serverTimestamp: "..." }        │
  │◄────────────────────────────────────────│
  │                                         │
```

### 8.2 Security Invariants

1. **Authentication:** Every sync request requires a valid JWT. Expired tokens are rejected with `401`.
2. **User isolation:** The server enforces that all change sets belong to the authenticated user. A change referencing another user's `rowId` is rejected with `403`.
3. **Schema validation:** The server validates every change set against the expected schema for that applet and table. Malformed payloads are rejected with `400`.
4. **Rate limiting:** Sync endpoints are rate-limited (see Section 4.1).
5. **Idempotency:** Each change set includes a client-generated idempotency key. Replaying the same change set is a no-op (the server returns the previously computed result).
6. **Payload size limit:** Maximum 1 MB per sync request. Larger change sets must be split by the client.

---

## 9. Privacy

### 9.1 Data Minimization

Super collects only the data necessary for functionality:

| Data | Collected | Stored Where | Purpose |
|------|-----------|-------------|---------|
| Username, email | Yes (via registration) | Server | Account identity |
| Todos, calendar events | Yes (user-created) | Client + server (if synced) | Core functionality |
| Conversation history | Yes (user-created) | Client only (default) | AI chatbot functionality |
| Home device data | Yes (via HomeKit) | Client only | Home control |
| Analytics / telemetry | **No** (unless user opts in) | N/A | N/A |
| Location | **No** | N/A | N/A |
| Contacts | **No** | N/A | N/A |

### 9.2 App Store Privacy Nutrition Label

Based on the data collection above, the privacy label declares:

- **Data Linked to You:** Email address (registration), user content (todos, calendar -- if synced).
- **Data Not Linked to You:** None collected.
- **Data Used to Track You:** None.
- **Data Not Collected:** Location, contacts, browsing history, diagnostics (unless opt-in).

### 9.3 Logging Policy

- **No PII in logs.** User IDs may appear in structured logs for debugging, but names, emails, and content are never logged.
- **No user content in metrics.** Metrics track counts and latencies, never payload contents.
- **Log retention:** Server logs retained for 30 days, then deleted.
- **AI conversations:** Never logged server-side beyond the lifetime of the LLM proxy request.

### 9.4 User Data Rights

| Right | Implementation |
|-------|----------------|
| **Data export** | `GET /api/v1/account/export` returns a ZIP containing all user data in JSON format. Available in app settings. |
| **Data deletion** | `DELETE /api/v1/account` deletes all server-side data within 24 hours. Client data is deleted immediately on the device. |
| **Conversation deletion** | Users can delete individual conversations or all conversation history from Chat settings. |
| **Account portability** | Export format is documented and machine-readable (JSON). |

### 9.5 Conversation Privacy

- Conversation history is stored locally only by default.
- If the user enables sync for conversations, they are synced to the server and treated as highest-sensitivity data.
- Users are informed at the point of enabling conversation sync that data will be stored on the server.
- Users can disable conversation sync at any time; server-side conversation data is deleted within 24 hours of disabling.

---

## 10. Incident Response

### 10.1 Incident Classification

| Severity | Description | Response Time |
|----------|-------------|---------------|
| **P0 — Critical** | Active data breach, unauthorized home device access, production API key compromised | Immediately (within 1 hour) |
| **P1 — High** | Vulnerability discovered in production, dependency CVE with known exploit | Within 4 hours |
| **P2 — Medium** | Dependency CVE without known exploit, security best-practice violation found | Within 24 hours |
| **P3 — Low** | Security improvement opportunity, minor hardening | Next sprint |

### 10.2 Response Playbooks

#### LLM API Key Compromised

1. Immediately rotate the API key with the LLM provider (Claude / Open Claw).
2. Update the server environment variable / secret manager with the new key.
3. Redeploy the backend.
4. Review LLM provider usage logs for unauthorized usage during the exposure window.
5. If unauthorized usage occurred, notify the LLM provider and request charges be reversed.
6. Investigate how the key was compromised (logs, CI history, access audit).

#### Unauthorized Home Device Access Reported

1. Advise user to immediately change their Apple ID password and revoke HomeKit access for any unrecognized users.
2. Review the Home action audit log (Section 6.3) on the user's device.
3. Check if the access came through Super (AI-initiated action) or through HomeKit directly.
4. If through Super: review server auth logs for the user's account, check for token theft.
5. If a vulnerability is confirmed, issue a hotfix and notify affected users.

#### Dependency CVE Discovered

1. Assess severity: does the CVE affect Super's usage of the dependency?
2. If exploitable: immediately update the dependency, test, and release a patch.
3. If not directly exploitable: schedule the update for the next release.
4. Run full CI pipeline including security scans after the update.
5. Document the CVE and response in the security log.

#### Compromised AI Agent in CI

1. Immediately revoke the agent's repository access token.
2. Review all PRs submitted by the agent in the past 30 days.
3. Check for unauthorized code changes, especially in security-critical files (auth, encryption, dependencies).
4. Revert any suspicious merged PRs.
5. Rotate any secrets that the agent could have accessed.
6. Investigate the root cause (prompt injection, model compromise, credential theft).

### 10.3 Security Contact

- **Reporting vulnerabilities:** security@super.app (or a dedicated reporting mechanism once established).
- **User-facing support:** In-app support channel for security concerns.
- **Responsible disclosure:** We commit to acknowledging reports within 48 hours and providing a timeline for remediation.

---

## 11. Security Checklist (Pre-Launch)

### 11.1 Authentication & Authorization

- [ ] All API endpoints (except `/auth/login`, `/health`) require a valid JWT
- [ ] JWT signature verification uses a strong algorithm (ES256 or RS256, not HS256 with a weak secret)
- [ ] Refresh token rotation is implemented and tested
- [ ] Stale refresh token reuse triggers full session revocation
- [ ] Per-user data isolation verified (user A cannot access user B's data)
- [ ] Username/password credentials are verified server-side with bcrypt (see [AUTH.md](./AUTH.md))

### 11.2 Encryption

- [ ] All client-server communication uses TLS 1.3
- [ ] SQLCipher enabled for Home and Chat databases
- [ ] Database encryption keys stored in Keychain with `ThisDeviceOnly` protection
- [ ] No secrets in the client binary (verified by scanning the IPA/app bundle)
- [ ] All Keychain items use appropriate protection classes
- [ ] Server disk encryption enabled

### 11.3 API Security

- [ ] Rate limiting enabled on all endpoints
- [ ] Zod validation on every request body
- [ ] No raw SQL construction from user input (all queries parameterized)
- [ ] Security response headers configured (HSTS, X-Content-Type-Options, etc.)
- [ ] CORS denies all origins (no web client in v1)
- [ ] Payload size limits enforced

### 11.4 AI/LLM Security

- [ ] LLM API keys exist only on the server, not in the client binary
- [ ] System prompt is server-controlled and cannot be overridden by client
- [ ] All tool calls are validated against the allowed tool set and parameter schemas
- [ ] Per-user token budget enforcement is active
- [ ] AI cannot call tools outside its registered set

### 11.5 Home Automation

- [ ] Destructive action confirmation (biometric) is enforced for all sensitive device types
- [ ] Action audit log records all home actions
- [ ] No home device credentials stored in Super's data (only in HomeKit)
- [ ] Rate limiting on AI-initiated home actions

### 11.6 CI/CD

- [ ] AI agents can only push to `agent/*` branches
- [ ] `main` branch requires human PR approval
- [ ] Signing certificates and production secrets are not accessible to agent CI steps
- [ ] Dependency vulnerability scanning (Dependabot/Snyk) runs on every PR
- [ ] CodeQL or equivalent static analysis runs on every PR
- [ ] Secret scanning enabled on the repository
- [ ] Lockfiles committed and checksums verified

### 11.7 Privacy

- [ ] App Store privacy nutrition label is accurate and up-to-date
- [ ] No PII in server logs or metrics
- [ ] Data export endpoint functional
- [ ] Account deletion endpoint functional (deletes all server-side data)
- [ ] Conversation history is local-only by default

### 11.8 Sync

- [ ] JWT required on every sync request
- [ ] User isolation enforced (cross-user data access impossible)
- [ ] Change set schema validation rejects malformed payloads
- [ ] Idempotency keys prevent duplicate processing
- [ ] Payload size limits enforced

### 11.9 Certificate Pinning

- [ ] Decision documented: pin or not (see Section 2.3.2 and Open Questions)
- [ ] If pinning: rotation plan documented, backup pins configured

---

## 12. Open Questions

These are unresolved decisions that require further evaluation. Each should be resolved with a written decision record before launch.

| # | Question | Options | Leaning | Blocking? |
|---|----------|---------|---------|-----------|
| 1 | **SQLCipher vs. OS-level encryption only?** | (a) SQLCipher for all applets, (b) SQLCipher for Home + Chat only, (c) OS-level only | (b) — SQLCipher for high-sensitivity applets, OS-level for others | No (ship with OS-level only, add SQLCipher before home automation launch) |
| 2 | **Certificate pinning: yes or no?** | (a) Pin the server cert leaf, (b) Pin intermediate CA, (c) No pinning | (c) — No pinning in v1 (see Section 2.3.2) | No |
| 3 | **E2EE for sync: v1 or later?** | (a) E2EE from day one, (b) E2EE as opt-in later, (c) Never | (b) — Start without E2EE, add as opt-in upgrade | No |
| 4 | **Passphrase-based encryption for exports?** | (a) Encrypted exports with user passphrase, (b) Unencrypted exports (rely on user securing the file) | (a) — Offer passphrase encryption, but allow unencrypted for convenience | No |
| 5 | **Server-side conversation storage?** | (a) Never store conversations server-side, (b) Store only if user enables sync, (c) Always store for cross-device access | (b) — Local-only default, opt-in sync | No |
| 6 | **JWT signing algorithm?** | (a) ES256 (ECDSA), (b) RS256 (RSA), (c) EdDSA | (a) — ES256 is compact and well-supported | Yes (must decide before auth implementation) |
| 7 | **Plaid token storage and rotation (Money)?** | (a) Store access tokens server-side only, rotate via Plaid's token rotation, (b) Store encrypted in client Keychain | (a) — Server-side only, client never sees Plaid tokens | No (Money is future scope) |

---

*Last updated: 2026-03-14*
