# Super: Server Architecture

> Backend architecture for the Super platform: gateway, per-applet services, admin dashboard, AI proxy, and deployment.

**Prerequisite reading:** [PRODUCT_VISION.md](./PRODUCT_VISION.md) for goals and applet descriptions, [AUTH.md](./AUTH.md) for authentication flows.

**Related documents:** [CLIENT_SERVER.md](./CLIENT_SERVER.md) for communication patterns between client and server, [MOBILE_ARCHITECTURE.md](./MOBILE_ARCHITECTURE.md) for the client-side architecture.

---

## 1. Overview & Guiding Constraints

The backend is intentionally thin. Most logic lives on-device (see [MOBILE_ARCHITECTURE.md](./MOBILE_ARCHITECTURE.md)). The server exists for:

1. **AI proxy** -- protect LLM API keys, enforce rate limits, validate tool calls server-side
2. **Auth** -- username/password authentication, JWT issuance and refresh (see [AUTH.md](./AUTH.md))
3. **Sync** -- cross-device data synchronization (change-set protocol over HTTPS)
4. **Admin dashboard** -- operational visibility into all services

These constraints shape every backend decision:

| Constraint | Implication |
|-----------|-------------|
| **Thin backend** | Most logic runs on-device. The server handles only what requires centralization: auth, AI key proxying, and sync. |
| **Self-hosted by developers** | `docker compose up` must bring up everything. No managed cloud services required (though cloud deployment is supported). |
| **Single developer operational surface** | One repo, one deployment unit (for v1). Avoid distributed systems complexity unless forced. |
| **Future microservice decomposition** | Service boundaries must be clear from day one so that individual services can be extracted to separate processes/containers in v2+. |
| **BYOK (Bring Your Own Key)** | Super is open source. API keys are never shipped. Users provide their own LLM provider keys, stored encrypted. |

---

## 2. Tech Stack

| Layer | Choice | Rationale |
|-------|--------|-----------|
| Runtime | Node.js 22+ | Fast development, excellent async I/O, huge ecosystem |
| Language | TypeScript (strict mode) | Type safety, refactorability, AI-agent friendly |
| Framework | Hono | Lightweight, fast, runs on any edge/serverless runtime |
| Database | PostgreSQL 16 | Proven, excellent for structured data, great tooling |
| ORM | Drizzle | Type-safe, lightweight, good migration story |
| Cache | Redis | Session cache, rate limiting, pub/sub |
| Logging | Pino | Structured JSON logging, low overhead |
| Validation | Zod | Runtime validation for request bodies and environment variables |
| Cloud hosting | Railway or Fly.io | Simple deployment, auto-scaling, managed Postgres |
| Self-hosted | Docker Compose | Primary target for v1. Single-command setup. |

---

## 3. Service Architecture -- Gateway + Services Pattern

The server follows a gateway + services pattern. In v1 all services run in-process as a monolith deployed in a single container. The service boundaries are designed so that in v2+ any service can be extracted to a separate process or container communicating via HTTP or a message queue.

### 3.1 Architecture Diagram

```
                    ┌─────────────────────────────────────────────┐
                    │              Gateway Server                  │
                    │  (Hono app: auth middleware, rate limiting,  │
                    │   logging, request routing, admin dashboard) │
                    └─────────┬───────┬───────┬───────────────────┘
                              │       │       │
              ┌───────────────┘       │       └───────────────┐
              ▼                       ▼                       ▼
     ┌─────────────┐        ┌──────────┐              ┌─────────────┐
     │  AI Service │        │   Auth   │              │    Sync     │
     │ (Chat)  │        │ Service  │              │   Service   │
     │             │        │          │              │             │
     │ /api/ai/*   │        │/api/auth │              │  /api/sync  │
     └─────────────┘        └──────────┘              └─────────────┘
              │                   │                          │
              └───────────────────┴──────────────┬──────────┘
                                                 ▼
                                      ┌──────────────────┐
                                      │  Shared Layer     │
                                      │  (DB, Redis,      │
                                      │   Config, Logger) │
                                      └──────────────────┘
```

### 3.2 Gateway Responsibilities

The gateway is the single entry point for all client requests. It handles:

- **Route mounting** -- auto-discovers and mounts service routes under their prefixes
- **Auth middleware** -- JWT verification on protected routes
- **Rate limiting** -- per-user, per-endpoint rate limits via Redis
- **Request logging** -- structured logging of all requests with Pino
- **Error handling** -- global error handler with consistent error response format
- **Admin dashboard** -- serves the admin UI at `/admin` (see Section 6)
- **Health check** -- `GET /health` aggregates health from all registered services
- **CORS** -- configured for the client origins

### 3.3 Service Modules

Each service module is a self-contained unit responsible for one domain:

| Service | Route prefix | Purpose | Required for v1? |
|---------|-------------|---------|-------------------|
| **AI** | `/api/ai/*` | LLM proxy, tool validation, token budgets | Yes |
| **Auth** | `/api/auth/*` | Username/password login, JWT issuance/refresh | Yes |
| **Sync** | `/api/sync/*` | Cross-device data synchronization | Yes |

Not every applet needs a backend service. Only applets that require server-side logic get one:

- **Chat** -- needs the AI proxy service
- **Sync** -- cross-cutting, serves all syncable applets
- **Money** -- may need a Plaid integration service in the future

Applets like ToDo, Calendar, and Home operate entirely on-device and interact with the server only through the sync service.

### 3.4 Directory Structure

```
super-server/
├── src/
│   ├── index.ts                        # Entry point, server startup
│   │
│   ├── gateway/
│   │   ├── server.ts                   # Hono app creation, service registration
│   │   ├── router.ts                   # Top-level route mounting
│   │   ├── middleware/
│   │   │   ├── auth.ts                 # JWT verification middleware
│   │   │   ├── rateLimit.ts            # Per-user, per-endpoint rate limits
│   │   │   ├── validation.ts           # Request body validation (Zod)
│   │   │   └── logging.ts             # Structured request logging (Pino)
│   │   ├── errors.ts                   # Error types + global error handler
│   │   └── health.ts                   # Aggregated health check endpoint
│   │
│   ├── services/
│   │   ├── ai/
│   │   │   ├── index.ts                # Service registration (exports ServiceModule)
│   │   │   ├── routes.ts               # POST /api/ai/chat, POST /api/ai/chat/stream
│   │   │   ├── service.ts              # LLM provider dispatch, streaming logic
│   │   │   ├── providers/
│   │   │   │   ├── claude.ts           # Anthropic API client
│   │   │   │   └── openClaw.ts         # Open Claw API client (future)
│   │   │   ├── toolValidator.ts        # Server-side tool call validation
│   │   │   ├── rateLimiter.ts          # AI-specific rate limiting (token budgets)
│   │   │   └── admin.ts               # Admin panel: provider status, token usage
│   │   │
│   │   ├── auth/
│   │   │   ├── index.ts                # Service registration
│   │   │   ├── routes.ts               # POST /api/auth/apple, POST /api/auth/refresh
│   │   │   ├── service.ts              # Apple ID token verification, JWT issuance
│   │   │   ├── tokens.ts              # JWT sign/verify helpers
│   │   │   └── admin.ts               # Admin panel: registered users
│   │   │
│   │   └── sync/
│   │       ├── index.ts                # Service registration
│   │       ├── routes.ts               # POST /api/sync/push, GET /api/sync/pull
│   │       ├── service.ts              # Change-set merge logic
│   │       └── admin.ts               # Admin panel: connected devices, last sync
│   │
│   ├── admin/
│   │   ├── dashboard.ts                # Main admin dashboard (aggregates panels)
│   │   └── templates.ts               # HTML template helpers
│   │
│   ├── shared/
│   │   ├── db.ts                       # Drizzle client + connection pool
│   │   ├── redis.ts                    # Redis client (ioredis)
│   │   ├── config.ts                   # Environment variables (Zod-validated)
│   │   └── logger.ts                  # Pino structured logger
│   │
│   └── db/
│       ├── schema.ts                   # Drizzle schema definitions
│       └── migrations/                 # Generated SQL migration files
│
├── docker-compose.yml                  # Postgres + Redis + server
├── Dockerfile
├── package.json
├── tsconfig.json
├── drizzle.config.ts
└── .env.example
```

### 3.5 Service Module Interface

Every service module exports a standard interface that the gateway auto-discovers and registers:

```typescript
// src/services/types.ts
import { Hono } from 'hono';

export interface ServiceModule {
  /** Unique service identifier */
  name: string;

  /** Route prefix (e.g., '/api/ai') */
  prefix: string;

  /** Hono sub-app with all routes for this service */
  routes: Hono;

  /** Health check for this service */
  healthCheck: () => Promise<ServiceHealth>;

  /** Admin dashboard panel (optional) */
  adminPanel?: AdminPanel;
}

export interface ServiceHealth {
  status: 'up' | 'down' | 'degraded';
  details?: Record<string, unknown>;
  latencyMs?: number;
}

export interface AdminPanel {
  /** Display name in the admin dashboard */
  title: string;

  /** Hono sub-app serving admin panel HTML */
  routes: Hono;

  /** Summary data for the dashboard overview */
  getSummary: () => Promise<AdminPanelSummary>;
}

export interface AdminPanelSummary {
  status: 'healthy' | 'warning' | 'error';
  metrics: { label: string; value: string | number }[];
}
```

### 3.6 Gateway Router Setup with Service Registration

```typescript
// src/gateway/server.ts
import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { logger as honoLogger } from 'hono/logger';
import { ServiceModule } from '../services/types';
import { authMiddleware } from './middleware/auth';
import { rateLimitMiddleware } from './middleware/rateLimit';
import { errorHandler } from './errors';
import { createAdminDashboard } from '../admin/dashboard';
import { config } from '../shared/config';
import { logger } from '../shared/logger';

// Import service modules
import { aiService } from '../services/ai';
import { authService } from '../services/auth';
import { syncService } from '../services/sync';

export function createServer(): Hono {
  const app = new Hono();

  // --- Global middleware ---
  app.use('*', cors({ origin: config.CORS_ORIGINS }));
  app.use('*', rateLimitMiddleware());
  app.onError(errorHandler);

  // --- Register services ---
  const services: ServiceModule[] = [
    aiService,
    authService,
    syncService,
  ];

  for (const service of services) {
    // Mount service routes under its prefix
    app.route(service.prefix, service.routes);
    logger.info({ service: service.name, prefix: service.prefix }, 'Service registered');
  }

  // --- Aggregated health check ---
  app.get('/health', async (c) => {
    const results: Record<string, ServiceHealth> = {};
    for (const service of services) {
      try {
        results[service.name] = await service.healthCheck();
      } catch (error) {
        results[service.name] = { status: 'down', details: { error: String(error) } };
      }
    }

    const overallStatus = Object.values(results).every(r => r.status === 'up')
      ? 'up'
      : Object.values(results).some(r => r.status === 'down')
        ? 'down'
        : 'degraded';

    return c.json({ status: overallStatus, services: results });
  });

  // --- Admin dashboard ---
  const adminPanels = services
    .filter(s => s.adminPanel)
    .map(s => ({ serviceName: s.name, panel: s.adminPanel! }));

  const adminApp = createAdminDashboard(adminPanels);
  app.route('/admin', adminApp);

  return app;
}
```

### 3.7 v1 vs v2+ Deployment

**v1 (monolith):** All services run in a single Node.js process. The `ServiceModule` interface is purely organizational -- it enforces clean boundaries without the overhead of network calls between services.

**v2+ (microservices):** Any service can be extracted to its own process/container:

1. The service's `routes` Hono app becomes its own standalone server
2. The gateway replaces the in-process route mount with an HTTP proxy (e.g., `hono/proxy` or a reverse proxy like Caddy/Nginx)
3. Inter-service communication switches from direct function calls to HTTP or a message queue (Redis Pub/Sub, NATS, etc.)
4. Each service gets its own Dockerfile and entry in `docker-compose.yml`

The `ServiceModule` interface makes this extraction mechanical, not architectural.

---

## 4. AI Proxy

The AI proxy is the most critical backend component. It is the security and cost boundary between clients and LLM providers. API keys never touch the client.

### 4.1 Responsibilities

1. **Rate limiting** -- per-user, per-endpoint limits to prevent abuse
2. **Token budget enforcement** -- per-user daily/monthly token caps to prevent cost runaway
3. **Tool validation** -- only allow tool calls that the user's active applets expose (defense in depth; the client also validates)
4. **System prompt injection** -- inject context about active applets and user preferences
5. **SSE streaming** -- stream LLM responses back to the client as Server-Sent Events
6. **Audit logging** -- log all tool calls for debugging and observability

### 4.2 Streaming Handler

```typescript
// src/services/ai/routes.ts
import { Hono } from 'hono';
import { streamSSE } from 'hono/streaming';
import { z } from 'zod';
import { zValidator } from '@hono/zod-validator';
import { authMiddleware } from '../../gateway/middleware/auth';
import { assertRateLimit } from './rateLimiter';
import { validateToolCall } from './toolValidator';
import { getProvider } from './providers';
import { logger } from '../../shared/logger';

const chatRequestSchema = z.object({
  messages: z.array(z.object({
    role: z.enum(['user', 'assistant']),
    content: z.string(),
  })),
  tools: z.array(z.object({
    name: z.string(),
    description: z.string(),
    parameters: z.record(z.unknown()),
  })).optional(),
});

const ai = new Hono();

// POST /api/ai/chat/stream
ai.post(
  '/chat/stream',
  authMiddleware(),
  zValidator('json', chatRequestSchema),
  async (c) => {
    const userId = c.get('userId');
    const { messages, tools } = c.req.valid('json');

    // 1. Rate limit check
    await assertRateLimit(userId, 'ai.chat');

    // 2. Token budget check (prevent cost runaway)
    const estimatedTokens = estimateTokenCount(messages);
    await assertTokenBudget(userId, estimatedTokens);

    // 3. Tool validation -- only allow tools the user's active applets expose
    const userApplets = await getUserActiveApplets(userId);
    const allowedTools = (tools ?? []).filter(t => isToolAllowed(t, userApplets));

    // 4. System prompt injection -- add context about active applets
    const systemPrompt = buildSystemPrompt(userApplets);

    // 5. Forward to LLM provider (streaming)
    const provider = await getProvider(userId);
    const stream = provider.stream(messages, allowedTools, systemPrompt);

    // 6. Stream response back to client (SSE)
    return streamSSE(c, async (sseStream) => {
      let outputTokens = 0;

      for await (const event of stream) {
        // Log tool calls for audit
        if (event.type === 'tool_use') {
          const validation = validateToolCall(event, allowedTools);
          if (!validation.valid) {
            logger.warn({
              userId,
              tool: event.name,
              reason: validation.reason,
            }, 'Tool call blocked by server validation');
            continue;
          }
          await logToolCall(userId, event);
        }

        if (event.type === 'text_delta') {
          outputTokens += estimateTokens(event.text);
        }

        await sseStream.writeSSE({
          data: JSON.stringify(event),
        });
      }

      // Record token usage
      await recordTokenUsage(userId, estimatedTokens, outputTokens);

      logger.info({
        event: 'ai.chat.stream.complete',
        userId,
        provider: provider.id,
        inputTokens: estimatedTokens,
        outputTokens,
        toolCalls: stream.toolCallNames ?? [],
      });
    });
  }
);

export { ai as aiRoutes };
```

### 4.3 Token Budget Enforcement

```typescript
// src/services/ai/rateLimiter.ts
import { redis } from '../../shared/redis';

interface RateLimitConfig {
  maxRequestsPerMinute: number;
  maxTokensPerDay: number;
  maxTokensPerMonth: number;
}

const DEFAULT_LIMITS: RateLimitConfig = {
  maxRequestsPerMinute: 20,
  maxTokensPerDay: 100_000,
  maxTokensPerMonth: 2_000_000,
};

export async function assertRateLimit(userId: string, endpoint: string): Promise<void> {
  const key = `rate:${userId}:${endpoint}`;
  const count = await redis.incr(key);
  if (count === 1) {
    await redis.expire(key, 60); // 1 minute window
  }
  if (count > DEFAULT_LIMITS.maxRequestsPerMinute) {
    throw new RateLimitError('Too many requests. Please wait before trying again.');
  }
}

export async function assertTokenBudget(userId: string, estimatedTokens: number): Promise<void> {
  const today = new Date().toISOString().slice(0, 10); // YYYY-MM-DD
  const month = today.slice(0, 7); // YYYY-MM

  const dailyKey = `tokens:${userId}:${today}`;
  const monthlyKey = `tokens:${userId}:${month}`;

  const [dailyUsage, monthlyUsage] = await Promise.all([
    redis.get(dailyKey).then(v => parseInt(v ?? '0', 10)),
    redis.get(monthlyKey).then(v => parseInt(v ?? '0', 10)),
  ]);

  if (dailyUsage + estimatedTokens > DEFAULT_LIMITS.maxTokensPerDay) {
    throw new TokenBudgetError('Daily token budget exceeded.');
  }
  if (monthlyUsage + estimatedTokens > DEFAULT_LIMITS.maxTokensPerMonth) {
    throw new TokenBudgetError('Monthly token budget exceeded.');
  }
}

export async function recordTokenUsage(
  userId: string,
  inputTokens: number,
  outputTokens: number,
): Promise<void> {
  const totalTokens = inputTokens + outputTokens;
  const today = new Date().toISOString().slice(0, 10);
  const month = today.slice(0, 7);

  const dailyKey = `tokens:${userId}:${today}`;
  const monthlyKey = `tokens:${userId}:${month}`;

  await Promise.all([
    redis.incrby(dailyKey, totalTokens),
    redis.expire(dailyKey, 86400 * 2), // TTL: 2 days
    redis.incrby(monthlyKey, totalTokens),
    redis.expire(monthlyKey, 86400 * 35), // TTL: 35 days
  ]);
}
```

---

## 5. Per-Applet Backend Services

### 5.1 AI Service (Chat)

The AI service is detailed in Section 4 above. It exports:

```typescript
// src/services/ai/index.ts
import { ServiceModule } from '../types';
import { aiRoutes } from './routes';
import { aiAdminPanel } from './admin';
import { redis } from '../../shared/redis';

export const aiService: ServiceModule = {
  name: 'ai',
  prefix: '/api/ai',
  routes: aiRoutes,

  healthCheck: async () => {
    try {
      // Check that we can reach at least one LLM provider
      const providerStatus = await checkProviderConnectivity();
      return {
        status: providerStatus ? 'up' : 'degraded',
        details: { providers: providerStatus },
      };
    } catch {
      return { status: 'down' };
    }
  },

  adminPanel: aiAdminPanel,
};
```

### 5.2 Auth Service

Handles username/password authentication and JWT lifecycle. See [AUTH.md](./AUTH.md) for the full authentication flow.

```typescript
// src/services/auth/index.ts
export const authService: ServiceModule = {
  name: 'auth',
  prefix: '/api/auth',
  routes: authRoutes,

  healthCheck: async () => {
    // Verify database connectivity (users table)
    const canQuery = await db.select().from(users).limit(1).then(() => true).catch(() => false);
    return { status: canQuery ? 'up' : 'down' };
  },

  adminPanel: authAdminPanel,
};
```

### 5.3 Sync Service

Receives change-sets from clients, merges them into Postgres, and serves pull requests for other devices. See [CLIENT_SERVER.md](./CLIENT_SERVER.md) for the sync protocol.

### 5.4 Service Registration Pattern

Each service module's `index.ts` exports a `ServiceModule` conforming to the interface in Section 3.5. The gateway imports all service modules and registers them in `createServer()`. To add a new per-applet service:

1. Create a new directory under `src/services/<service-name>/`
2. Implement the `ServiceModule` interface
3. Import and add it to the `services` array in `src/gateway/server.ts`

The gateway handles all cross-cutting concerns (auth, rate limiting, logging). Services focus purely on domain logic.

---

## 6. Admin Dashboard

### 6.1 Overview

The admin dashboard is served by the gateway at `/admin`. It is protected by auth middleware (admin role required). For v1, it is simple server-rendered HTML using Hono's built-in `html` helper. No React SPA, no build step.

### 6.2 Dashboard Layout

The main dashboard shows:

- **System health overview** -- aggregated status from all service health checks
- **Registered services** -- list with status indicator (up/down/degraded) for each
- **Resource usage** -- basic metrics from Redis (memory, connected clients)

Each service can inject its own admin panel with service-specific views:

| Service | Admin panel shows |
|---------|-------------------|
| **AI** | Active LLM providers, token usage stats (daily/monthly), recent conversations (metadata only, not content) |
| **Sync** | Connected devices per user, last sync timestamps per device |
| **Auth** | Registered user count, recent sign-ins |

### 6.3 Admin Dashboard Implementation

```typescript
// src/admin/dashboard.ts
import { Hono } from 'hono';
import { html } from 'hono/html';
import { authMiddleware, requireAdmin } from '../gateway/middleware/auth';
import { AdminPanel, AdminPanelSummary } from '../services/types';

interface RegisteredPanel {
  serviceName: string;
  panel: AdminPanel;
}

export function createAdminDashboard(panels: RegisteredPanel[]): Hono {
  const admin = new Hono();

  // Protect all admin routes
  admin.use('*', authMiddleware());
  admin.use('*', requireAdmin());

  // Main dashboard
  admin.get('/', async (c) => {
    const summaries: { name: string; title: string; summary: AdminPanelSummary }[] = [];

    for (const { serviceName, panel } of panels) {
      try {
        const summary = await panel.getSummary();
        summaries.push({ name: serviceName, title: panel.title, summary });
      } catch {
        summaries.push({
          name: serviceName,
          title: panel.title,
          summary: { status: 'error', metrics: [{ label: 'Error', value: 'Failed to load' }] },
        });
      }
    }

    return c.html(renderDashboard(summaries));
  });

  // Mount each service's admin panel routes
  for (const { serviceName, panel } of panels) {
    admin.route(`/${serviceName}`, panel.routes);
  }

  return admin;
}

function renderDashboard(
  summaries: { name: string; title: string; summary: AdminPanelSummary }[]
): string {
  const statusIcon = (status: string) =>
    status === 'healthy' ? '[ OK ]'
    : status === 'warning' ? '[WARN]'
    : '[ERR ]';

  const panelCards = summaries.map(({ name, title, summary }) => html`
    <div class="panel-card ${summary.status}">
      <h3><a href="/admin/${name}">${title}</a></h3>
      <span class="status">${statusIcon(summary.status)}</span>
      <ul>
        ${summary.metrics.map(m => html`<li><strong>${m.label}:</strong> ${m.value}</li>`)}
      </ul>
    </div>
  `).join('');

  return html`
    <!DOCTYPE html>
    <html>
    <head>
      <title>Super Admin</title>
      <style>
        body { font-family: system-ui, sans-serif; max-width: 900px; margin: 2rem auto; padding: 0 1rem; }
        .panel-card { border: 1px solid #ddd; border-radius: 8px; padding: 1rem; margin: 1rem 0; }
        .panel-card.healthy { border-left: 4px solid #22c55e; }
        .panel-card.warning { border-left: 4px solid #f59e0b; }
        .panel-card.error { border-left: 4px solid #ef4444; }
        .status { font-family: monospace; }
        ul { list-style: none; padding: 0; }
        li { margin: 0.25rem 0; }
        a { color: #2563eb; text-decoration: none; }
        a:hover { text-decoration: underline; }
      </style>
    </head>
    <body>
      <h1>Super Admin Dashboard</h1>
      <p>System overview. Click a service name for its detailed panel.</p>
      ${panelCards}
    </body>
    </html>
  `;
}
```

### 6.4 Example: AI Service Admin Panel

```typescript
// src/services/ai/admin.ts
import { Hono } from 'hono';
import { html } from 'hono/html';
import { AdminPanel } from '../types';
import { redis } from '../../shared/redis';

const adminRoutes = new Hono();

adminRoutes.get('/', async (c) => {
  const providers = await getActiveProviders();
  const todayKey = `tokens:*:${new Date().toISOString().slice(0, 10)}`;
  const tokenUsageToday = await aggregateTokenUsage('daily');
  const tokenUsageMonth = await aggregateTokenUsage('monthly');

  return c.html(html`
    <h2>AI Service</h2>
    <h3>Active Providers</h3>
    <ul>
      ${providers.map(p => html`<li>${p.name} -- ${p.status}</li>`)}
    </ul>
    <h3>Token Usage</h3>
    <p>Today: ${tokenUsageToday.toLocaleString()} tokens</p>
    <p>This month: ${tokenUsageMonth.toLocaleString()} tokens</p>
    <p><a href="/admin">Back to dashboard</a></p>
  `);
});

export const aiAdminPanel: AdminPanel = {
  title: 'AI Service (Chat)',
  routes: adminRoutes,

  getSummary: async () => {
    const providers = await getActiveProviders();
    const tokenUsageToday = await aggregateTokenUsage('daily');

    return {
      status: providers.some(p => p.status === 'up') ? 'healthy' : 'error',
      metrics: [
        { label: 'Active providers', value: providers.filter(p => p.status === 'up').length },
        { label: 'Tokens today', value: tokenUsageToday.toLocaleString() },
      ],
    };
  },
};
```

### 6.5 Future

For v1, the server-rendered HTML approach is sufficient. If the admin dashboard grows in complexity, it could be upgraded to a proper frontend framework (React, Svelte, etc.) served as static assets.

---

## 7. Server-Side Tool Validation

Defense in depth: the server validates tool calls even though the client also validates. This prevents a compromised or buggy client from executing invalid tool calls.

```typescript
// src/services/ai/toolValidator.ts

interface ToolCall {
  name: string;
  parameters: Record<string, unknown>;
}

interface Tool {
  name: string;
  parameters: {
    name: string;
    type: string;
    required: boolean;
  }[];
}

interface ValidationResult {
  valid: boolean;
  reason?: string;
}

export function validateToolCall(toolCall: ToolCall, allowedTools: Tool[]): ValidationResult {
  const tool = allowedTools.find(t => t.name === toolCall.name);
  if (!tool) {
    return { valid: false, reason: `Tool not registered: ${toolCall.name}` };
  }

  // Check required parameters
  for (const param of tool.parameters.filter(p => p.required)) {
    if (!(param.name in toolCall.parameters)) {
      return { valid: false, reason: `Missing required param: ${param.name}` };
    }
  }

  // Type check parameters
  for (const [key, value] of Object.entries(toolCall.parameters)) {
    const param = tool.parameters.find(p => p.name === key);
    if (!param) continue; // Extra params are ignored, not rejected
    if (!typeCheck(value, param.type)) {
      return { valid: false, reason: `Invalid type for ${key}: expected ${param.type}` };
    }
  }

  return { valid: true };
}

function typeCheck(value: unknown, expectedType: string): boolean {
  switch (expectedType) {
    case 'string': return typeof value === 'string';
    case 'number':
    case 'int': return typeof value === 'number';
    case 'boolean':
    case 'bool': return typeof value === 'boolean';
    case 'date': return typeof value === 'string' && !isNaN(Date.parse(value));
    default:
      // Enum types: "enum:low,medium,high,urgent"
      if (expectedType.startsWith('enum:')) {
        const allowed = expectedType.slice(5).split(',');
        return typeof value === 'string' && allowed.includes(value);
      }
      return true; // Unknown types pass (fail-open for extensibility)
  }
}
```

---

## 8. Database Schema

Drizzle schema definitions for the server-side Postgres database. Per-applet tables are namespaced with the applet prefix to keep the schema organized as more applets add server-side tables.

### 9.1 Core Tables

```typescript
// src/db/schema.ts
import { pgTable, text, timestamp, boolean, integer, jsonb, uuid } from 'drizzle-orm/pg-core';

// --- Users ---
export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  appleUserId: text('apple_user_id').unique().notNull(),
  email: text('email'),                                  // optional, from Apple ID
  displayName: text('display_name'),
  role: text('role').notNull().default('user'),           // 'user' | 'admin'
  createdAt: timestamp('created_at').defaultNow().notNull(),
  updatedAt: timestamp('updated_at').defaultNow().notNull(),
});

// --- Sessions / Refresh Tokens ---
export const sessions = pgTable('sessions', {
  id: uuid('id').primaryKey().defaultRandom(),
  userId: uuid('user_id').references(() => users.id).notNull(),
  refreshToken: text('refresh_token').unique().notNull(),
  deviceId: text('device_id'),                           // identifies the device
  deviceName: text('device_name'),                       // e.g., "Brian's iPhone"
  expiresAt: timestamp('expires_at').notNull(),
  createdAt: timestamp('created_at').defaultNow().notNull(),
});

// --- Sync State ---
export const syncDevices = pgTable('sync_devices', {
  id: uuid('id').primaryKey().defaultRandom(),
  userId: uuid('user_id').references(() => users.id).notNull(),
  deviceId: text('device_id').notNull(),
  deviceName: text('device_name'),
  lastSyncAt: timestamp('last_sync_at'),
  createdAt: timestamp('created_at').defaultNow().notNull(),
});

export const syncChanges = pgTable('sync_changes', {
  id: uuid('id').primaryKey().defaultRandom(),
  userId: uuid('user_id').references(() => users.id).notNull(),
  deviceId: text('device_id').notNull(),
  applet: text('applet').notNull(),                      // e.g., 'todo', 'calendar'
  tableName: text('table_name').notNull(),               // e.g., 'tasks', 'events'
  recordId: text('record_id').notNull(),
  operation: text('operation').notNull(),                 // 'insert' | 'update' | 'delete'
  changePayload: jsonb('change_payload'),
  timestamp: timestamp('timestamp').notNull(),
  createdAt: timestamp('created_at').defaultNow().notNull(),
});
```

### 9.2 Per-Applet Namespaced Tables

Applet-specific server-side tables use a prefix to avoid collisions:

```typescript
// --- ToDo (sync targets) ---
export const todoTasks = pgTable('todo_tasks', {
  id: text('id').primaryKey(),
  userId: uuid('user_id').references(() => users.id).notNull(),
  title: text('title').notNull(),
  priority: text('priority').notNull().default('medium'),
  dueDate: timestamp('due_date'),
  isCompleted: boolean('is_completed').notNull().default(false),
  projectId: text('project_id'),
  createdAt: timestamp('created_at').notNull(),
  updatedAt: timestamp('updated_at').notNull(),
});

// --- Calendar (sync targets) ---
export const calendarEvents = pgTable('calendar_events', {
  id: text('id').primaryKey(),
  userId: uuid('user_id').references(() => users.id).notNull(),
  title: text('title').notNull(),
  startDate: timestamp('start_date').notNull(),
  endDate: timestamp('end_date'),
  isAllDay: boolean('is_all_day').notNull().default(false),
  location: text('location'),
  notes: text('notes'),
  createdAt: timestamp('created_at').notNull(),
  updatedAt: timestamp('updated_at').notNull(),
});
```

### 9.3 Migration Strategy

Drizzle generates SQL migrations from schema changes:

```bash
# Generate migration from schema diff
npx drizzle-kit generate

# Apply migrations
npx drizzle-kit migrate

# Or programmatically at server startup
import { migrate } from 'drizzle-orm/node-postgres/migrator';
await migrate(db, { migrationsFolder: './src/db/migrations' });
```

Migrations run automatically on server startup (in `src/index.ts`), ensuring the database schema is always up to date with the code.

---

## 9. Configuration & Environment

### 10.1 Zod-Validated Environment Variables

```typescript
// src/shared/config.ts
import { z } from 'zod';

const envSchema = z.object({
  // Server
  PORT: z.coerce.number().default(3000),
  NODE_ENV: z.enum(['development', 'production', 'test']).default('development'),
  CORS_ORIGINS: z.string().transform(s => s.split(',')),

  // Database
  DATABASE_URL: z.string().url(),

  // Redis
  REDIS_URL: z.string().url(),

  // Auth
  JWT_SECRET: z.string().min(32),
  JWT_ACCESS_TOKEN_EXPIRY: z.string().default('15m'),
  JWT_REFRESH_TOKEN_EXPIRY: z.string().default('30d'),
  APPLE_TEAM_ID: z.string(),
  APPLE_SERVICE_ID: z.string(),

  // AI Providers (BYOK -- these are the server operator's keys)
  ANTHROPIC_API_KEY: z.string().optional(),
  OPEN_CLAW_API_KEY: z.string().optional(),

  // Rate limiting
  RATE_LIMIT_AI_RPM: z.coerce.number().default(20),
  TOKEN_BUDGET_DAILY: z.coerce.number().default(100_000),
  TOKEN_BUDGET_MONTHLY: z.coerce.number().default(2_000_000),

  // Admin
  ADMIN_PASSWORD: z.string().min(8).optional(),

  // Logging
  LOG_LEVEL: z.enum(['trace', 'debug', 'info', 'warn', 'error', 'fatal']).default('info'),
});

export const config = envSchema.parse(process.env);
export type Config = z.infer<typeof envSchema>;
```

### 10.2 .env.example

```bash
# .env.example -- Copy to .env and fill in values
# ================================================

# Server
PORT=3000
NODE_ENV=development
CORS_ORIGINS=http://localhost:3000,super://

# Database (Docker Compose default)
DATABASE_URL=postgresql://super:super@localhost:5432/super

# Redis (Docker Compose default)
REDIS_URL=redis://localhost:6379

# Auth
JWT_SECRET=your-secret-key-at-least-32-characters-long
JWT_ACCESS_TOKEN_EXPIRY=15m
JWT_REFRESH_TOKEN_EXPIRY=30d
APPLE_TEAM_ID=YOUR_TEAM_ID
APPLE_SERVICE_ID=YOUR_SERVICE_ID

# AI Providers (provide at least one)
ANTHROPIC_API_KEY=sk-ant-...
# OPEN_CLAW_API_KEY=

# Rate limiting
RATE_LIMIT_AI_RPM=20
TOKEN_BUDGET_DAILY=100000
TOKEN_BUDGET_MONTHLY=2000000

# Admin
ADMIN_PASSWORD=changeme-in-production

# Logging
LOG_LEVEL=debug
```

### 10.3 Docker Compose

```yaml
# docker-compose.yml
version: '3.8'

services:
  server:
    build: .
    ports:
      - '${PORT:-3000}:3000'
    environment:
      - NODE_ENV=${NODE_ENV:-development}
      - DATABASE_URL=postgresql://super:super@postgres:5432/super
      - REDIS_URL=redis://redis:6379
    env_file:
      - .env
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    restart: unless-stopped

  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: super
      POSTGRES_PASSWORD: super
      POSTGRES_DB: super
    ports:
      - '5432:5432'
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U super']
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    ports:
      - '6379:6379'
    volumes:
      - redisdata:/data
    healthcheck:
      test: ['CMD', 'redis-cli', 'ping']
      interval: 5s
      timeout: 5s
      retries: 5
    command: redis-server --appendonly yes

volumes:
  pgdata:
  redisdata:
```

### 10.4 Dockerfile

```dockerfile
FROM node:22-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:22-alpine
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./
EXPOSE 3000
CMD ["node", "dist/index.js"]
```

---

## 10. Deployment

### 11.1 Self-Hosted (Primary Target for v1)

The primary deployment target is Docker Compose on a developer's own machine or VPS:

```bash
# Clone, configure, and run
git clone https://github.com/user/super-server.git
cd super-server
cp .env.example .env
# Edit .env with your API keys and secrets
docker compose up -d
```

This single command brings up Postgres, Redis, and the server. Migrations run automatically on startup.

### 11.2 Cloud (Railway / Fly.io)

For developers who prefer managed infrastructure:

**Railway:**
1. Connect your GitHub repo
2. Railway auto-detects the Dockerfile
3. Add a Postgres plugin and Redis plugin
4. Set environment variables in the Railway dashboard
5. Deploy

**Fly.io:**
```bash
fly launch
fly postgres create --name super-db
fly redis create --name super-redis
fly secrets set JWT_SECRET=... ANTHROPIC_API_KEY=...
fly deploy
```

### 11.3 Production Checklist

- [ ] Set `NODE_ENV=production`
- [ ] Use a strong, unique `JWT_SECRET` (not the example value)
- [ ] Set `ADMIN_PASSWORD` to something secure
- [ ] Configure `CORS_ORIGINS` to only allow your app's origins
- [ ] Enable Postgres SSL (`?sslmode=require` in `DATABASE_URL`)
- [ ] Set up automated database backups
- [ ] Configure log aggregation (e.g., ship Pino JSON logs to a log service)
- [ ] Set up uptime monitoring on the `/health` endpoint

---

## 11. Logging & Observability

### 12.1 Pino Structured Logging

```typescript
// src/shared/logger.ts
import pino from 'pino';
import { config } from './config';

export const logger = pino({
  level: config.LOG_LEVEL,
  transport: config.NODE_ENV === 'development'
    ? { target: 'pino-pretty', options: { colorize: true } }
    : undefined,  // JSON output in production
  base: {
    service: 'super-server',
    env: config.NODE_ENV,
  },
});
```

### 12.2 Key Metrics

| Metric | Source | Why |
|--------|--------|-----|
| Request latency (p50, p95, p99) | Gateway middleware | Detect performance regressions |
| AI response latency (time to first token) | AI service | User-perceived speed |
| Token usage per user (daily/monthly) | AI service / Redis | Cost monitoring |
| Tool call success/failure rate | AI service | Reliability indicator |
| Active sessions | Auth service / DB | User engagement |
| Sync latency (push/pull duration) | Sync service | Sync health |
| Database connection pool utilization | Drizzle / pg pool | Capacity planning |
| Redis memory usage | Redis INFO | Capacity planning |

### 12.3 Health Check Endpoint

```typescript
// src/gateway/health.ts
import { Hono } from 'hono';
import { db } from '../shared/db';
import { redis } from '../shared/redis';
import { sql } from 'drizzle-orm';

const health = new Hono();

health.get('/', async (c) => {
  const checks: Record<string, { status: string; latencyMs: number }> = {};

  // Postgres
  const pgStart = Date.now();
  try {
    await db.execute(sql`SELECT 1`);
    checks.postgres = { status: 'up', latencyMs: Date.now() - pgStart };
  } catch {
    checks.postgres = { status: 'down', latencyMs: Date.now() - pgStart };
  }

  // Redis
  const redisStart = Date.now();
  try {
    await redis.ping();
    checks.redis = { status: 'up', latencyMs: Date.now() - redisStart };
  } catch {
    checks.redis = { status: 'down', latencyMs: Date.now() - redisStart };
  }

  const allUp = Object.values(checks).every(c => c.status === 'up');

  return c.json({
    status: allUp ? 'up' : 'degraded',
    timestamp: new Date().toISOString(),
    checks,
  }, allUp ? 200 : 503);
});

export { health as healthRoutes };
```

### 12.4 Request Logging Middleware

```typescript
// src/gateway/middleware/logging.ts
import { MiddlewareHandler } from 'hono';
import { logger } from '../../shared/logger';

export const requestLogging = (): MiddlewareHandler => {
  return async (c, next) => {
    const start = Date.now();
    const requestId = crypto.randomUUID();

    c.set('requestId', requestId);

    await next();

    const latencyMs = Date.now() - start;

    logger.info({
      event: 'http.request',
      requestId,
      method: c.req.method,
      path: c.req.path,
      status: c.res.status,
      latencyMs,
      userId: c.get('userId') ?? null,
    });
  };
};
```

---

## 12. Decision Log

Relevant server-side architectural decisions.

| # | Date | Decision | Rationale | Status |
|---|------|----------|-----------|--------|
| ADR-002 | 2026-03-13 | Single backend with module separation | Solo dev; multiple backends multiply operational overhead without benefit at this scale. **Evolution:** module boundaries are now formalized as `ServiceModule` interfaces to enable future extraction to microservices. v1 remains a monolith. | Accepted, Evolved |
| ADR-009 | 2026-03-13 | TypeScript + Hono for backend | Fast development velocity, lightweight, runs anywhere (Node, Deno, Bun, edge runtimes). Hono's middleware composition maps naturally to the gateway pattern. | Accepted |
| ADR-012 | 2026-03-16 | Gateway + Services pattern (in-process for v1) | Formalizes service boundaries without the operational overhead of actual microservices. Each service module exports a standard `ServiceModule` interface so extraction to separate processes is mechanical when the time comes. | Accepted |
| ADR-013 | 2026-03-16 | Server-rendered admin dashboard (no SPA) | For v1, a simple server-rendered HTML dashboard (Hono `html` helper) is sufficient. Avoids a separate build pipeline, JS bundle, and framework dependency. Each service injects its own panel via the `AdminPanel` interface. | Accepted |
| ADR-014 | 2026-03-16 | Docker Compose as primary deployment target | Self-hosting with `docker compose up` is the simplest operational surface for a solo developer. Cloud deployment (Railway/Fly.io) is supported but not required. | Accepted |
