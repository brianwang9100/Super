# Super: Development Setup

Self-host guide for developers who want to clone the repo, run the backend locally, and build the iOS/macOS client.

---

## 1. Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| macOS | 15+ | Required for Xcode and iOS development |
| Xcode | 16+ | Swift 6, SwiftUI |
| Docker Desktop | Latest | Runs Postgres, Redis, and the server |
| Node.js | 22+ | Optional — only needed if running the server outside Docker |
| Git | Latest | |

## 2. Clone & Repository Structure

```bash
git clone https://github.com/user/Super.git
cd Super
```

```
Super/
├── CLAUDE.md
├── docs/                    # Design & architecture docs
├── Core/                    # Shared Swift Package
├── Chat/                # AI chat applet
├── ToDo/                   # Todo applet
├── Calendar/                  # Calendar applet
├── Home/                 # Home assistant applet
├── Notifications/                # Notifications applet
├── Money/                # Finance applet
├── Super/                # Shell app target (Xcode project)
└── super-server/         # Backend (TypeScript/Hono)
    ├── docker-compose.yml
    ├── Dockerfile
    └── src/
```

## 3. Backend Setup

```bash
cd super-server
cp .env.example .env
docker compose up -d
```

This starts three containers: Postgres, Redis, and the Hono server.

The server listens at `http://localhost:3000`. Verify it's running:

```bash
curl http://localhost:3000/health
```

See [Section 10](#10-environment-variables-reference) for the full list of `.env` variables.

## 4. Server First-Run Wizard

Open `http://localhost:3000/admin/setup` in a browser.

**Step 1 — Create admin account.** Choose a username and password. This is what you'll use to log in from the iOS/macOS client.

**Step 2 — Configure LLM provider.** Pick Claude or Open Claw, enter the API key, and hit "Test connection" to verify it works.

**Step 3 — Enable applets.** The following are pre-enabled by default:

| Applet | Server config needed? |
|--------|-----------------------|
| Chat | Already configured in Step 2 (LLM key) |
| ToDo | None |
| Calendar | None |
| Notifications | None |

Optional applets you can enable:

| Applet | Requirement |
|--------|-------------|
| Money | Plaid client ID, secret, and environment (sandbox/development) |
| Home | No server config — HomeKit permission is prompted on device |

**Step 4 — Review & finish.**

After setup, the admin dashboard is accessible at `http://localhost:3000/admin` (requires login). You can change applet configuration there at any time.

## 5. iOS / macOS Client Setup

Open `Super.xcodeproj` in Xcode. Swift packages (GRDB, GRDBQuery, GRDBSnapshotTesting) resolve automatically via SPM.

### Configure the server URL

| Target | URL | How to set |
|--------|-----|------------|
| Simulator | `http://localhost:3000` | Default in debug builds |
| Physical device | `http://192.168.1.x:3000` (your Mac's local IP) | Scheme environment variable or `ServerConfig.swift` |

### Build and run

1. Select a simulator or connected device, then build and run.
2. On first launch the login screen appears. Enter the credentials you created during the server first-run wizard.
3. After login the app fetches `GET /api/config` and auto-configures the enabled applets. No client-side applet selection is needed.

Applets that require device permissions (Calendar for EventKit, Home for HomeKit, Notifications for notifications) will prompt on first open.

## 6. The Config Endpoint

`GET /api/config` (authenticated) returns the server's applet configuration:

```json
{
  "enabledApplets": [
    { "id": "chat", "displayName": "Chat", "requiresClientSetup": false },
    { "id": "todo", "displayName": "ToDo", "requiresClientSetup": false },
    { "id": "calendar", "displayName": "Calendar", "requiresClientSetup": false },
    { "id": "notifications", "displayName": "Notifications", "requiresClientSetup": false },
    { "id": "home", "displayName": "Home", "requiresClientSetup": true, "clientSetupHint": "HomeKit permission required" }
  ],
  "llmProvider": "claude",
  "syncEnabled": true,
  "serverVersion": "1.0.0"
}
```

The client uses this response to populate its `AppletRegistry`. It re-fetches on every app foreground so changes made in the admin dashboard take effect without a reinstall.

## 7. Running Tests

**Client tests** use in-memory GRDB and don't need a running server:

```bash
xcodebuild test -project Super.xcodeproj -scheme Super -destination 'platform=iOS Simulator,name=iPhone 16'
```

Or run from Xcode with Cmd+U.

**Server tests** use a Docker Compose test profile with an isolated Postgres instance:

```bash
cd super-server
npm test
```

Per-applet test suites can run independently.

## 8. Development Workflow

- **Backend hot-reload:** The server runs with `--watch` inside Docker and auto-restarts on file changes in `super-server/src/`.
- **iOS client:** Standard Xcode build-and-run cycle.
- **Core package changes:** All applets that depend on `Core/` will rebuild automatically.
- **Adding a new applet:** See the plugin contract in [DESIGN.md](DESIGN.md) Section 6.

## 8.5 MCP tooling (agent build/run)

Agent-driven builds, simulator runs, and UI smoke tests on this project rely on two MCP servers wired in `.mcp.json` at the repo root. Configuration is checked in so every contributor (and every agent session) picks them up automatically — no per-machine setup beyond `npx` (Node 22+).

| Server | Package | What it does |
|--------|---------|--------------|
| `xcodebuild` | `xcodebuildmcp` | Drives `xcodebuild` (build, test, run on simulator), boots and installs to simulators, tails `os_log`. The primary way agents validate that the app compiles and runs. |
| `ios-simulator` | `ios-simulator-mcp` | Automates UI interaction on the iOS simulator (taps, gestures, screenshots, accessibility tree inspection). Used by agents to smoke-test UI changes and capture screenshots for PR descriptions. |

`.mcp.json` (already at the repo root):

```json
{
  "mcpServers": {
    "xcodebuild":   { "command": "npx", "args": ["-y", "xcodebuildmcp@latest"] },
    "ios-simulator":{ "command": "npx", "args": ["-y", "ios-simulator-mcp@latest"] }
  }
}
```

The plan originally referenced an "Axiom MCP" for iOS-simulator UI automation — `ios-simulator-mcp` (`joshuayoes/ios-simulator-mcp`) is the actual published package that fits that role and is what we wire here. Update this section if a better-fit server lands later.

### Smoke checks

Once the agent harness picks up `.mcp.json`:

- `mcp__xcodebuild__list_schemes` (or equivalent in your harness) should return at least the `Super` scheme.
- `mcp__ios-simulator__list_simulators` should return the iPhone simulator family.

### Per-agent permission allowlist

`.claude/settings.json` (also at the repo root, project-shared and checked in) grants Claude permission to call these MCP tools and a small set of safe Bash commands (`swift test`, `xcodebuild`, `xcrun simctl`, `git status/diff/log/add/commit`) without an interactive prompt. Per-developer overrides should go in `.claude/settings.local.json`, which is excluded from version control by convention.

### Fallback to plain Bash

Every MCP action has a plain-`bash` equivalent — `xcodebuild -scheme Super -destination ...`, `xcrun simctl boot ...`, `xcrun simctl install ...`. The MCPs are an accelerator, not a blocker. If an MCP is unavailable, agents fall back to bash and the build/test loop continues.

## 9. Troubleshooting

### Common issues

| Problem | Fix |
|---------|-----|
| "Connection refused" on physical device | Use your Mac's local IP, not `localhost`. Check with `ifconfig en0`. |
| Docker containers won't start | Make sure Docker Desktop is running. Check that ports 3000, 5432, and 6379 are free. |
| "Unauthorized" after login | Verify `JWT_SECRET` in `.env` is set and hasn't changed since you created your account. |
| Swift package resolution fails | Xcode menu: File > Packages > Reset Package Caches. |

### Useful commands

```bash
# Tail server logs
docker compose logs -f server

# Reset everything (destroys all data)
docker compose down -v

# Connect to Postgres directly
docker compose exec postgres psql -U super

# Rebuild server container after Dockerfile changes
docker compose up -d --build server
```

## 10. Environment Variables Reference

All variables are set in `super-server/.env`.

| Variable | Description | Default | Required? |
|----------|-------------|---------|-----------|
| `DATABASE_URL` | Postgres connection string | Set by docker-compose | No (auto in Docker) |
| `REDIS_URL` | Redis connection string | Set by docker-compose | No (auto in Docker) |
| `JWT_SECRET` | Secret for signing JWTs | — | Yes |
| `LLM_PROVIDER` | `"claude"` or `"openclaw"` | — | Yes |
| `CLAUDE_API_KEY` | Anthropic API key | — | Yes, if provider is Claude |
| `OPENCLAW_API_URL` | Open Claw server URL | — | Yes, if provider is Open Claw |
| `OPENCLAW_API_KEY` | Open Claw API key | — | Yes, if provider is Open Claw |
| `PLAID_CLIENT_ID` | Plaid client ID | — | Only for Money |
| `PLAID_SECRET` | Plaid secret | — | Only for Money |
| `PLAID_ENV` | `sandbox` / `development` / `production` | — | Only for Money |
| `PORT` | Server port | `3000` | No |
| `LOG_LEVEL` | Pino log level | `"info"` | No |

Generate a JWT secret:

```bash
openssl rand -base64 32
```

---

For architecture details see [DESIGN.md](DESIGN.md). For auth flow see [AUTH.md](AUTH.md). For backend internals see [SERVER_ARCHITECTURE.md](SERVER_ARCHITECTURE.md).
