# Super: Authentication

> Simple, self-hosted authentication for a single developer deploying Super from source.

**Prerequisite reading:** [CLIENT_SERVER.md](./CLIENT_SERVER.md) for the AuthInterceptor and token management, [SERVER_ARCHITECTURE.md](./SERVER_ARCHITECTURE.md) for the server auth service. [SECURITY.md](./SECURITY.md) Section 3 for token design, biometric unlock, and backend authorization patterns.

> **Status (2026-05-03):** Not built yet. The MVP has no login — the app drops directly into Chat on launch and persists locally. The only secret today is the user's BYOK LLM API key, which lives in the iOS Keychain and never leaves the device. Tracked in [`TODO.md`](../TODO.md) § Server.

---

## 1. Overview

Super v1 targets a single user: the developer who clones the repo and self-hosts the backend. The authentication system is designed around this constraint.

| Principle | Implication |
|-----------|-------------|
| **Single user, self-hosted** | No public registration endpoint. The developer creates their account via the admin dashboard. |
| **Simple credentials** | Username + password. No Sign in with Apple dependency (see [Decision Log](#10-decision-log)). |
| **BYOK** | API keys for LLM providers, Plaid, etc. are managed separately from auth. Auth proves identity; BYOK manages service access. |
| **JWT tokens** | Short-lived access token (15 min) + long-lived refresh token (30 days), consistent with the token design in [SECURITY.md](./SECURITY.md) Section 3.2. |
| **Schema supports multi-user** | The `users` table supports multiple rows. UI and flows are single-user for v1. |

---

## 2. Registration / Account Setup

There is no public registration endpoint. The developer creates their account through the admin dashboard — a simple web UI served by the backend.

### Flow

1. Developer starts the backend for the first time.
2. If no user exists in the database, the admin dashboard shows a **Create Account** form.
3. Developer enters a username and password.
4. Server hashes the password and inserts a row into the `users` table.
5. The admin dashboard shows a confirmation and redirects to the login page.

### Password Hashing

Passwords are hashed with **argon2id** (preferred) before storage. Never store or log plaintext passwords.

```typescript
import { hash, verify } from '@node-rs/argon2';

// Registration
const passwordHash = await hash(plaintext, {
  memoryCost: 65536,   // 64 MB
  timeCost: 3,
  parallelism: 1,
  outputLen: 32,
});

// Login verification
const isValid = await verify(passwordHash, plaintext);
```

### Drizzle Schema

```typescript
// src/db/schema.ts
import { pgTable, uuid, varchar, timestamp, boolean } from 'drizzle-orm/pg-core';

export const users = pgTable('users', {
  id: uuid('id').defaultRandom().primaryKey(),
  username: varchar('username', { length: 64 }).notNull().unique(),
  passwordHash: varchar('password_hash', { length: 255 }).notNull(),
  createdAt: timestamp('created_at').defaultNow().notNull(),
  updatedAt: timestamp('updated_at').defaultNow().notNull(),
});

export const refreshTokens = pgTable('refresh_tokens', {
  id: uuid('id').defaultRandom().primaryKey(),
  userId: uuid('user_id').references(() => users.id, { onDelete: 'cascade' }).notNull(),
  tokenHash: varchar('token_hash', { length: 255 }).notNull(),
  expiresAt: timestamp('expires_at').notNull(),
  createdAt: timestamp('created_at').defaultNow().notNull(),
  revoked: boolean('revoked').default(false).notNull(),
});
```

---

## 3. Login Flow

The iOS/macOS app presents a login screen on first launch (or when no valid tokens exist in Keychain).

### Sequence

```
┌────────┐                          ┌────────┐
│ Client │                          │ Server │
└───┬────┘                          └───┬────┘
    │                                   │
    │  1. POST /auth/login              │
    │     { username, password }        │
    │─────────────────────────────────►│
    │                                   │
    │                                   │  2. Look up user by username
    │                                   │  3. Verify password (argon2id)
    │                                   │  4. Generate access + refresh tokens
    │                                   │  5. Store refresh token hash in DB
    │                                   │
    │  6. { accessToken, refreshToken } │
    │◄─────────────────────────────────│
    │                                   │
    │  7. Store refresh token           │
    │     in Keychain                   │
    │  8. Hold access token             │
    │     in memory only                │
    │                                   │
```

### Server Route

```typescript
// src/modules/auth/routes.ts
import { Hono } from 'hono';
import { z } from 'zod';
import { zValidator } from '@hono/zod-validator';
import { eq } from 'drizzle-orm';
import { verify } from '@node-rs/argon2';
import { db } from '../../shared/db';
import { users, refreshTokens } from '../../db/schema';
import { signAccessToken, generateRefreshToken, hashToken } from './tokens';

const loginSchema = z.object({
  username: z.string().min(1).max(64),
  password: z.string().min(8).max(128),
});

const auth = new Hono();

auth.post('/login', zValidator('json', loginSchema), async (c) => {
  const { username, password } = c.req.valid('json');

  // 1. Find user
  const user = await db.query.users.findFirst({
    where: eq(users.username, username),
  });

  if (!user) {
    // Constant-time: still run argon2 to prevent timing attacks
    await verify('$argon2id$v=19$m=65536,t=3,p=1$dummy', password).catch(() => {});
    return c.json({ error: 'Invalid credentials' }, 401);
  }

  // 2. Verify password
  const valid = await verify(user.passwordHash, password);
  if (!valid) {
    return c.json({ error: 'Invalid credentials' }, 401);
  }

  // 3. Issue tokens
  const accessToken = await signAccessToken({ sub: user.id });
  const refreshToken = generateRefreshToken();

  // 4. Store refresh token hash
  await db.insert(refreshTokens).values({
    userId: user.id,
    tokenHash: hashToken(refreshToken),
    expiresAt: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000), // 30 days
  });

  return c.json({ accessToken, refreshToken });
});

export { auth };
```

### Client Login

```swift
// LoginViewModel.swift
@Observable @MainActor
final class LoginViewModel {
    var username = ""
    var password = ""
    var isLoading = false
    var errorMessage: String?

    private let httpClient: HTTPClient
    private let authInterceptor: AuthInterceptor
    private let keychainStore: KeychainStore

    func login() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        do {
            let response: AuthResponse = try await httpClient.request(
                .login(username: username, password: password),
                responseType: AuthResponse.self
            )
            await authInterceptor.setTokens(
                access: response.accessToken,
                refresh: response.refreshToken
            )
            try keychainStore.save(
                response.refreshToken,
                forKey: .refreshToken,
                accessibility: .whenUnlockedThisDeviceOnly
            )
        } catch {
            errorMessage = "Login failed. Check your credentials and try again."
        }
    }
}

struct AuthResponse: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
}
```

---

## 4. Token Management

Token design follows [SECURITY.md](./SECURITY.md) Section 3.2. This section covers the runtime mechanics.

### Access Token

- JWT, signed with ES256 (see [SECURITY.md](./SECURITY.md) open decision #6).
- 15-minute lifetime.
- Held in memory only (never persisted to disk).
- Injected into every request by `AuthInterceptor`.

### Refresh Token

- Opaque, random 256-bit value.
- 30-day lifetime.
- Stored hashed (SHA-256) in the `refresh_tokens` table.
- Stored in Keychain on the client with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Rotated on every use.

### Token Refresh Flow

```
┌────────┐                          ┌────────┐
│ Client │                          │ Server │
└───┬────┘                          └───┬────┘
    │                                   │
    │  1. API request with expired JWT  │
    │─────────────────────────────────►│
    │                                   │
    │  2. 401 Unauthorized              │
    │◄─────────────────────────────────│  (AuthInterceptor detects expiry
    │                                   │   before sending, or handles 401)
    │  3. POST /auth/refresh            │
    │     { refreshToken }              │
    │─────────────────────────────────►│
    │                                   │  4. Hash incoming token
    │                                   │  5. Look up hash in refresh_tokens
    │                                   │  6. Verify not revoked, not expired
    │                                   │  7. Revoke old token
    │                                   │  8. Issue new access + refresh tokens
    │                                   │  9. Store new refresh token hash
    │                                   │
    │  10. { accessToken, refreshToken }│
    │◄─────────────────────────────────│
    │                                   │
    │  11. Update Keychain              │
    │  12. Retry original request       │
    │                                   │
```

### Refresh Token Rotation & Theft Detection

Each refresh rotates the token. If a previously-rotated (stale) token is presented, it indicates theft. The server revokes **all** refresh tokens for that user, forcing re-authentication on all devices.

```typescript
// src/modules/auth/routes.ts (continued)
auth.post('/refresh', async (c) => {
  const { refreshToken } = await c.req.json();
  const tokenHash = hashToken(refreshToken);

  const stored = await db.query.refreshTokens.findFirst({
    where: eq(refreshTokens.tokenHash, tokenHash),
  });

  if (!stored) {
    // Possible theft: a rotated token was replayed.
    // Revoke all tokens for the user who originally owned this token.
    // (Requires a lookup — see implementation note below.)
    return c.json({ error: 'Invalid refresh token' }, 401);
  }

  if (stored.revoked || stored.expiresAt < new Date()) {
    // Stale token reuse — revoke everything for this user
    await db
      .update(refreshTokens)
      .set({ revoked: true })
      .where(eq(refreshTokens.userId, stored.userId));
    return c.json({ error: 'Token revoked. Please log in again.' }, 401);
  }

  // Rotate: revoke old, issue new
  await db
    .update(refreshTokens)
    .set({ revoked: true })
    .where(eq(refreshTokens.id, stored.id));

  const newRefreshToken = generateRefreshToken();
  await db.insert(refreshTokens).values({
    userId: stored.userId,
    tokenHash: hashToken(newRefreshToken),
    expiresAt: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000),
  });

  const accessToken = await signAccessToken({ sub: stored.userId });

  return c.json({ accessToken, refreshToken: newRefreshToken });
});
```

### Client AuthInterceptor

The `AuthInterceptor` actor is defined in [CLIENT_SERVER.md](./CLIENT_SERVER.md). The full implementation with login/logout support:

```swift
actor AuthInterceptor {
    private var accessToken: String?
    private var refreshToken: String?
    private var refreshTask: Task<String, Error>?

    private let httpClient: URLSession
    private let keychainStore: KeychainStore
    private let baseURL: URL

    enum AuthError: Error, Sendable {
        case notAuthenticated
        case refreshFailed
    }

    init(baseURL: URL, keychainStore: KeychainStore) {
        self.baseURL = baseURL
        self.keychainStore = keychainStore
        self.httpClient = URLSession.shared
        // Restore refresh token from Keychain on init
        self.refreshToken = try? keychainStore.read(forKey: .refreshToken)
    }

    /// Set tokens after a successful login.
    func setTokens(access: String, refresh: String) {
        self.accessToken = access
        self.refreshToken = refresh
    }

    /// Clear all tokens (logout).
    func clearTokens() {
        self.accessToken = nil
        self.refreshToken = nil
        try? keychainStore.delete(forKey: .refreshToken)
    }

    /// Injects the current access token into the request.
    /// If expired, silently refreshes first (coalescing concurrent attempts).
    func intercept(_ request: URLRequest) async throws -> URLRequest {
        let token = try await validAccessToken()
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validAccessToken() async throws -> String {
        if let token = accessToken, !isExpired(token) {
            return token
        }
        // Coalesce concurrent refresh attempts
        if let existing = refreshTask {
            return try await existing.value
        }
        let task = Task { try await refreshAccessToken() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func refreshAccessToken() async throws -> String {
        guard let refreshToken else {
            throw AuthError.notAuthenticated
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("auth/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["refreshToken": refreshToken])

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            clearTokens()
            throw AuthError.refreshFailed
        }

        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
        self.accessToken = authResponse.accessToken
        self.refreshToken = authResponse.refreshToken

        try keychainStore.save(
            authResponse.refreshToken,
            forKey: .refreshToken,
            accessibility: .whenUnlockedThisDeviceOnly
        )

        return authResponse.accessToken
    }

    private func isExpired(_ token: String) -> Bool {
        // Decode JWT payload, check exp claim with a 30-second buffer
        guard let payload = decodeJWTPayload(token),
              let exp = payload["exp"] as? TimeInterval else {
            return true
        }
        return Date(timeIntervalSince1970: exp).addingTimeInterval(-30) < Date()
    }
}
```

---

## 5. Server Implementation

### JWT Signing

```typescript
// src/modules/auth/tokens.ts
import { SignJWT, jwtVerify } from 'jose';
import { createHash, randomBytes } from 'crypto';
import { config } from '../../shared/config';

const privateKey = await importPKCS8(config.JWT_PRIVATE_KEY, 'ES256');
const publicKey = await importSPKI(config.JWT_PUBLIC_KEY, 'ES256');

export async function signAccessToken(claims: { sub: string }): Promise<string> {
  return new SignJWT(claims)
    .setProtectedHeader({ alg: 'ES256' })
    .setIssuer('super-api')
    .setAudience('super-client')
    .setIssuedAt()
    .setExpirationTime('15m')
    .sign(privateKey);
}

export async function verifyAccessToken(token: string) {
  return jwtVerify(token, publicKey, {
    issuer: 'super-api',
    audience: 'super-client',
  });
}

export function generateRefreshToken(): string {
  return randomBytes(32).toString('base64url');
}

export function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}
```

### Auth Middleware

The auth middleware in `src/gateway/middleware/auth.ts` is already described in [SECURITY.md](./SECURITY.md) Section 3.4. It extracts the user ID from the verified JWT and sets it on the context. All protected routes use this middleware.

### Route Registration

```typescript
// src/modules/auth/routes.ts — register under the top-level router
// POST /auth/login     — username/password login (unauthenticated)
// POST /auth/refresh   — refresh token rotation (unauthenticated)
// POST /auth/logout    — revoke refresh token (authenticated)

auth.post('/logout', authMiddleware, async (c) => {
  const userId = c.get('userId');
  // Revoke all refresh tokens for this user
  await db
    .update(refreshTokens)
    .set({ revoked: true })
    .where(eq(refreshTokens.userId, userId));
  return c.json({ success: true });
});
```

### Environment Variables

```
# .env (never committed)
JWT_PRIVATE_KEY=<ES256 private key in PEM format>
JWT_PUBLIC_KEY=<ES256 public key in PEM format>
DATABASE_URL=postgres://...
REDIS_URL=redis://...
```

Generate a key pair during setup:

```bash
openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out es256-private.pem
openssl ec -in es256-private.pem -pubout -out es256-public.pem
```

---

## 6. Client Implementation

### Keychain Storage

```swift
struct KeychainStore: Sendable {
    enum Key: String, Sendable {
        case refreshToken = "com.super.auth.refreshToken"
        case serverURL = "com.super.auth.serverURL"
    }

    enum Accessibility {
        case whenUnlockedThisDeviceOnly
        case afterFirstUnlockThisDeviceOnly

        var secValue: CFString {
            switch self {
            case .whenUnlockedThisDeviceOnly:
                return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            case .afterFirstUnlockThisDeviceOnly:
                return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
        }
    }

    func save(_ value: String, forKey key: Key, accessibility: Accessibility) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility.secValue,
        ]
        SecItemDelete(query as CFDictionary) // Remove existing
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    func read(forKey key: Key) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.readFailed(status)
        }
        return string
    }

    func delete(forKey key: Key) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: Error {
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
}
```

### Login View

```swift
struct LoginView: View {
    @State private var viewModel: LoginViewModel

    var body: some View {
        VStack(spacing: 24) {
            Text("Super")
                .font(.largeTitle.bold())

            TextField("Username", text: $viewModel.username)
                .textContentType(.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            SecureField("Password", text: $viewModel.password)
                .textContentType(.password)

            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Button("Log In") {
                Task { await viewModel.login() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isLoading || viewModel.username.isEmpty || viewModel.password.isEmpty)
        }
        .padding()
    }
}
```

### Auth State Observation

The app root decides whether to show `LoginView` or the main shell based on auth state:

```swift
@Observable @MainActor
final class AppAuthState {
    enum State: Sendable {
        case unknown      // Checking Keychain on launch
        case loggedOut
        case loggedIn
    }

    private(set) var state: State = .unknown

    private let authInterceptor: AuthInterceptor

    func checkAuthOnLaunch() async {
        // AuthInterceptor restores refresh token from Keychain on init.
        // Try a token refresh to validate the session.
        do {
            _ = try await authInterceptor.intercept(URLRequest(url: URL(string: "https://placeholder")!))
            state = .loggedIn
        } catch {
            state = .loggedOut
        }
    }

    func didLogin() {
        state = .loggedIn
    }

    func didLogout() async {
        await authInterceptor.clearTokens()
        state = .loggedOut
    }
}
```

---

## 7. Admin Dashboard Account Management

The admin dashboard is a simple web UI served by the backend at `/admin`. It is protected by session-based auth (the developer logs in via the same credentials).

### v1 Scope

- **Setup page** (`/admin/setup`): shown when no user exists. Create the first (and only) account.
- **Account page** (`/admin/account`): change username, change password, view active sessions (refresh tokens), revoke sessions.
- **API keys page** (`/admin/keys`): manage BYOK API keys (LLM providers, etc.). Keys are stored in encrypted columns — see [SECURITY.md](./SECURITY.md) Section 2 for encryption details.

### Password Change

When the password changes:

1. Verify the current password.
2. Hash the new password with argon2id.
3. Update the `users` row.
4. Revoke **all** refresh tokens for the user (forces re-login on all devices).

```typescript
auth.post('/admin/change-password', authMiddleware, async (c) => {
  const userId = c.get('userId');
  const { currentPassword, newPassword } = await c.req.json();

  const user = await db.query.users.findFirst({
    where: eq(users.id, userId),
  });

  if (!user || !(await verify(user.passwordHash, currentPassword))) {
    return c.json({ error: 'Current password is incorrect' }, 401);
  }

  const newHash = await hash(newPassword, {
    memoryCost: 65536,
    timeCost: 3,
    parallelism: 1,
    outputLen: 32,
  });

  await db.update(users).set({
    passwordHash: newHash,
    updatedAt: new Date(),
  }).where(eq(users.id, userId));

  // Revoke all refresh tokens — forces re-login
  await db
    .update(refreshTokens)
    .set({ revoked: true })
    .where(eq(refreshTokens.userId, userId));

  return c.json({ success: true });
});
```

### Future: Multi-User Dashboard

See [Section 9](#9-future-multi-user) for the planned expansion of the admin dashboard.

---

## 8. Security Considerations

Most security details live in [SECURITY.md](./SECURITY.md). This section highlights auth-specific concerns.

| Concern | Mitigation |
|---------|-----------|
| **HTTPS required** | All auth endpoints must be served over TLS. The backend should reject non-TLS connections in production. |
| **Password hashing** | argon2id with recommended parameters (64 MB memory, 3 iterations). Never bcrypt — argon2id is the current standard. |
| **No plaintext passwords** | Passwords are hashed on arrival. Never logged, never stored in plaintext, never returned in API responses. |
| **Rate limiting on login** | 10 requests per minute per IP on `/auth/login`. Uses Redis sliding window. See [SECURITY.md](./SECURITY.md) Section 4.2. |
| **Timing-safe comparison** | On login failure, always run argon2 verify (even if user not found) to prevent username enumeration via timing. |
| **Token revocation on password change** | All refresh tokens are revoked when the password changes. |
| **Refresh token theft detection** | Stale token reuse revokes all tokens for the user. See Section 4. |
| **Access token in memory only** | Never persisted to disk. Lost on app termination; recovered via refresh. |
| **Refresh token in Keychain** | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — not included in backups, not available when locked. |

---

## 9. Future: Multi-User

The database schema already supports multiple users (the `users` table has no single-row constraint). When multi-user is needed:

### What Changes

1. **Admin dashboard**: add a user list page. The first user becomes the admin. Admin can create/delete users and assign roles.
2. **Roles**: add a `role` column to `users` (`admin`, `member`). Admin can manage other users and system settings. Members can only use the app.
3. **Per-user API key storage**: each user brings their own API keys. The `api_keys` table gets a `user_id` foreign key. See [SECURITY.md](./SECURITY.md) Section 2 for encryption of stored keys.
4. **Per-user sync**: sync partitions data by `user_id`. Each user's change sets are isolated. See [SYNC.md](./SYNC.md) for the sync engine design.
5. **Registration flow**: admin generates invite codes or manually creates accounts. Still no public registration.

### What Stays the Same

- JWT token structure (already has `sub` claim with user ID).
- Refresh token rotation.
- `AuthInterceptor` on the client.
- Backend authorization middleware (already scopes queries by `userId`).
- Password hashing.

---

## 10. Decision Log

### ADR: Username/Password over Sign in with Apple for v1

**Status:** Accepted

**Context:** Super is an open-source, self-hosted app. The initial target user is a developer running the backend on their own infrastructure.

**Options considered:**

| Option | Pros | Cons |
|--------|------|------|
| **Sign in with Apple** | Native iOS integration, no password management, trusted by users | Requires Apple Developer Program enrollment for the self-hosting developer. Backend must verify tokens with Apple's servers (external dependency). Complicates open-source setup. Doesn't work well for self-hosted scenarios where the developer may not have an Apple Developer account. |
| **Username/password** | No external dependencies. Works for any self-hosted setup. Simple to implement and understand. Developer controls everything. | Developer must manage their own password. Less secure than delegated auth if password is weak. |
| **Magic link (email)** | No password to manage. | Requires email infrastructure (SMTP). Over-engineered for a single self-hosted user. |

**Decision:** Username/password.

**Rationale:**
- The self-hosting developer should not need an Apple Developer Program membership just to authenticate with their own server.
- No external service dependencies for auth (no Apple token verification, no SMTP).
- The developer is technical and can choose a strong password.
- The schema supports adding Sign in with Apple later (add an `apple_id` column to `users`, add `/auth/apple` route alongside `/auth/login`).

**Consequences:**
- The developer is responsible for choosing a strong password.
- The admin dashboard must enforce minimum password requirements (8+ characters).
- When/if Sign in with Apple is added later, it will be an additional auth method, not a replacement.
