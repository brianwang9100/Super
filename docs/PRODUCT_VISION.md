# Super: Product Vision & Architecture

> A modular, AI-first personal productivity platform where independent applications communicate seamlessly through an intelligent orchestration layer.

---

## 1. Executive Summary

Super is a native Apple platform application (iOS + macOS) that unifies personal productivity tools — AI Chatbot, Calendar, Todo List, and Home Assistant — into a cohesive experience. Each applet operates independently but, when connected, communicates through an event-driven architecture orchestrated by the AI chatbot. The defining experience is **natural language as the universal remote**: a user speaks or types a command, and the system responds with coordinated actions and animations across applets.

---

## 2. Core Principles

### 2.1 Modularity First
Each application (Chatbot, Calendar, Todos, Home) is a fully independent applet with its own data layer, business logic, and UI. Applets communicate exclusively through a well-defined event bus and shared protocol layer. This enables:
- Independent development and testing of each applet
- One AI agent per applet during the build phase
- Future extensibility (add new applets without touching existing ones)
- Each applet can ship as a standalone app if desired

### 2.2 AI as Orchestrator, Not Gatekeeper
The AI chatbot is the orchestration layer but never the *only* way to interact. Every action the AI can perform is also available through direct UI interaction. The AI adds convenience and cross-applet coordination — it does not gatekeep functionality.

### 2.3 Animation as Feedback Language
Cross-applet actions are made tangible through purposeful animations. When the AI adds a todo item, the user *sees* it materialize in the todo list. When the temperature changes, the Home Assistant applet visually reflects it. These animations are not decorative — they are the system's way of confirming "I understood you, and here's what I did."

### 2.4 Offline-First

The app must work without a network — on a plane, in a subway, anywhere. This is a non-negotiable constraint, not a nice-to-have.

- **Data is on-device first.** GRDB/SQLite is the local source of truth. Cloud sync is additive — replication and backup, never a runtime dependency.
- **LLMs run locally when possible.** On-device models (MLX, Apple Foundation Models) are the preferred configuration. Cloud LLM providers (Claude, OpenAI-compatible) are supported but optional. Chat must function with a local model alone.
- **Tools default to local execution.** Each AI tool runs on-device unless it genuinely requires network — for example, a self-hosted smart home server that exposes its own API. Local vs. remote is a per-tool decision, not a per-applet one; a single applet may mix both (e.g. local cache read + remote refresh).
- **Graceful degradation, not failure.** When a feature genuinely needs network and network is unavailable, the UI says so. Nothing else breaks.

The only features that inherently require connectivity are: remote tool calls (by definition), multi-device sync, and cloud LLM providers when selected as the active model. Everything else — including AI chat with a local model — works offline.

### 2.5 Privacy by Default
Personal productivity data is sensitive. All data at rest is encrypted. Home automation credentials never leave the device. LLM interactions are stateless on the server side — no conversation history is stored remotely unless the user opts in.

---

## 3. Target Platforms

| Platform | Framework | Priority |
|----------|-----------|----------|
| iOS (iPhone/iPad) | SwiftUI | P0 — primary target |
| macOS | SwiftUI (Catalyst or native) | P0 — simultaneous launch |
| watchOS | SwiftUI (Chatbot + Home only) | P2 — future |
| Web | TBD (React/Next.js or skip) | P3 — evaluate later |
| Android | TBD (Kotlin Multiplatform) | P3 — evaluate later |

**Decision: SwiftUI is the primary UI framework.** It allows maximum code sharing between iOS and macOS while delivering native performance and animation capabilities. Platform-specific adaptations (sidebar navigation on Mac, tab bar on iPhone) are handled through SwiftUI's adaptive layout system.

---

## 4. Applet Breakdown

### 4.1 AI Chatbot ("Chat")

**Purpose:** Natural language interface and cross-applet orchestrator.

**Core Capabilities:**
- Conversational AI powered by Claude API (tool use / function calling)
- Streaming responses with real-time token rendering
- Context-aware: understands which applets are active and their current state
- Multi-turn conversations with local history
- Voice input (Speech-to-text) and voice output (Text-to-speech)

**Tool/Function Calling Architecture:**
Each applet registers "tools" with the chatbot. When the user makes a request, the AI determines which tools to call. Example tools:
```
todo.create(title, description?, priority?, due_date?)
todo.update(id, fields...)
todo.list(filter?)
calendar.create_event(title, start, end, location?)
calendar.list_events(date_range)
home.set_temperature(zone, temperature)
home.toggle_device(device_id, state)
home.get_status(device_id?)
```

**AI Model Choice:** Claude (via Anthropic API) — selected for strong tool use capabilities, long context window, and reliable instruction following. The architecture should be model-agnostic through an adapter layer, allowing future swaps.

**Key UX Details:**
- Chat interface with rich message bubbles (text, cards, action confirmations)
- "Action cards" appear inline when the AI performs a cross-applet action
- Typing indicator, streaming text, and tool-call progress animations
- Conversation history stored locally (GRDB), optionally synced

---

### 4.2 Calendar ("Calendar")

**Purpose:** Personal calendar with smart scheduling and AI integration.

**Core Capabilities:**
- Day / Week / Month views with smooth animated transitions
- Event CRUD with recurrence, reminders, and location support
- Integration with Apple Calendar (EventKit) for system calendar sync
- AI-powered features: natural language event creation, schedule analysis, conflict detection
- Time blocking and focus mode integration

**Key UX Details:**
- When AI creates an event, it animates into the calendar view (the event "drops in" to its time slot)
- Drag-and-drop rescheduling with haptic feedback
- Color-coded categories synced with todo priorities

**Data Model:**
- Local: GRDB structs (Event, Recurrence, Reminder)
- Sync: EventKit bridge for Apple Calendar interop + optional custom backend sync for Super-specific metadata

---

### 4.3 Todo List ("ToDo")

**Purpose:** Linear/Jira-like task management for personal use.

**Core Capabilities:**
- Projects, tasks, and subtasks with hierarchy
- Status workflow: Backlog → Todo → In Progress → Done → Archived
- Priority levels (Urgent, High, Medium, Low) with visual indicators
- Labels / tags for categorization
- Kanban board view and list view
- Due dates with calendar integration (shows in Calendar)
- AI-powered: natural language task creation, priority suggestion, task breakdown

**Key UX Details:**
- When AI creates a task, it animates into the appropriate column/list with a "materialization" effect
- Drag-and-drop between status columns (Kanban) with spring animations
- Swipe actions for quick status changes
- Badge count on the applet tab for overdue/urgent items

**Data Model:**
- Local: GRDB structs (Project, Task, Subtask, Label)
- Sync: Custom backend sync

---

### 4.4 Home Assistant ("Home")

**Purpose:** Smart home control and monitoring with AI integration.

**Core Capabilities:**
- HomeKit integration (primary) for Apple ecosystem devices
- Matter protocol support for broader device compatibility
- Device control: lights, thermostats, locks, cameras, sensors
- Scene management (e.g., "Movie Night", "Good Morning")
- Automation rules with scheduling
- AI-powered: natural language device control, scene creation, automation suggestions

**Key UX Details:**
- Room-based layout with device tiles
- When AI changes a device state, the tile animates (thermostat dial rotates, light icon dims/brightens, etc.)
- Real-time status updates via HomeKit delegate callbacks
- Energy usage dashboard (if supported by devices)

**Integration Layer:**
- HomeKit (HMHomeManager) as the primary integration
- Future: Home Assistant (open source) REST API integration for non-HomeKit devices
- Future: MQTT bridge for custom IoT devices

---

## 5. Architecture

### 5.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Super App                      │
│  ┌──────────┐ ┌──────────┐ ┌────────┐ ┌──────────┐ │
│  │ Chat │ │  Calendar  │ │ ToDo  │ │ Home  │ │
│  │(Chatbot) │ │(Calendar)│ │(Todos) │ │ (Home)   │ │
│  └────┬─────┘ └────┬─────┘ └───┬────┘ └────┬─────┘ │
│       │             │           │            │       │
│  ┌────▼─────────────▼───────────▼────────────▼────┐  │
│  │              Event Bus (SuperBus)            │  │
│  │         (Combine Publishers / AsyncStream)      │  │
│  └────┬───────────────────────────────────────────┘  │
│       │                                              │
│  ┌────▼──────────────────────────────────────────┐   │
│  │          Shared Services Layer                 │   │
│  │  ┌────────┐ ┌──────────┐ ┌──────────────────┐│   │
│  │  │  Auth  │ │ Storage  │ │ Animation Engine ││   │
│  │  └────────┘ └──────────┘ └──────────────────┘│   │
│  └───────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
          │
          ▼
┌──────────────────────┐
│   Backend Services   │
│  ┌────────────────┐  │
│  │  API Gateway   │  │
│  │  (orchestrator)│  │
│  └───────┬────────┘  │
│    ┌─────┼─────┐     │
│    ▼     ▼     ▼     │
│  ┌───┐┌───┐┌─────┐  │
│  │AI ││Sync││Auth │  │
│  └───┘└───┘└─────┘  │
└──────────────────────┘
```

### 5.2 Key Architectural Decision: Native UI over Server-Driven UI

**Decision: Native SwiftUI for all core UI. No server-driven UI system.**

**Rationale:**
- **Animations are the product's identity.** Server-driven UI frameworks add latency and severely limit animation capabilities. The cross-applet animations (a todo "flying" into the list, a thermostat dial spinning) require native animation primitives (SwiftUI `withAnimation`, `matchedGeometryEffect`, custom `Animatable` conformances).
- **Offline requirement.** Server-driven UI breaks when offline. A local-first app needs its UI defined locally.
- **Complexity budget.** Building a custom SDUI framework is a multi-month project in itself. That engineering time is better spent on the actual product.
- **When SDUI *would* make sense:** If Super later needs rapidly-changing promotional content, onboarding flows, or A/B tested layouts. At that point, a lightweight SDUI layer for *non-critical* content areas can be added without rearchitecting.

**Compromise approach for dynamic content:** The AI chatbot responses can include structured "action cards" defined as JSON payloads that map to predefined SwiftUI card templates. This gives some server-driven flexibility for chat content without building a full SDUI system.

### 5.3 Key Architectural Decision: Backend Strategy

**Decision: Thin unified backend with domain-separated service modules.**

**Rationale for a single backend (not one per app):**
- For a solo developer / small team, multiple backends multiply operational overhead (deployments, monitoring, infra) without proportional benefit at this scale.
- The inter-service communication between separate backends adds latency and complexity.
- A single backend with clean internal module separation achieves the same code organization benefits.

**Backend Structure:**
```
super-server/
├── src/
│   ├── gateway/          # API gateway, routing, auth middleware
│   ├── modules/
│   │   ├── ai/           # LLM proxy, tool dispatch, conversation mgmt
│   │   ├── calendar/     # Calendar sync, sharing (future)
│   │   ├── todos/        # Todo sync, collaboration (future)
│   │   └── home/         # Device state relay (future, if needed)
│   ├── shared/           # Auth, database, event bus
│   └── main.ts
```

**When to split into microservices:** If/when Super gains significant users and individual modules need independent scaling. The clean module boundaries make this a straightforward future migration.

**Backend Tech Stack Recommendation:**
- **Runtime:** Node.js with TypeScript (fast development, excellent ecosystem, easy deployment)
- **Alternative:** Swift on Server (Vapor) — appealing for full-stack Swift but smaller ecosystem and slower development velocity for a solo dev
- **Database:** PostgreSQL (structured data, proven, excellent tooling)
- **Cache / Pub-Sub:** Redis (session cache, real-time sync pub/sub)
- **Hosting:** Railway, Fly.io, or AWS (ECS/Lambda) — start simple, scale later
- **AI Proxy:** Backend proxies Claude API calls to protect API keys and enable server-side tool execution

### 5.4 Event Bus Design (Client-Side)

The event bus is the nervous system of Super. It enables applets to communicate without direct dependencies.

**Implementation: Combine + AsyncStream hybrid**

```swift
// Core event types
enum SuperEvent {
    // Todo events
    case todoCreated(Todo)
    case todoUpdated(Todo, changes: [String: Any])
    case todoDeleted(id: UUID)

    // Calendar events
    case calendarEventCreated(CalendarEvent)
    case calendarEventUpdated(CalendarEvent)

    // Home events
    case deviceStateChanged(deviceId: String, state: DeviceState)
    case sceneActivated(sceneId: String)

    // AI events
    case aiActionStarted(action: AIAction)
    case aiActionCompleted(action: AIAction, result: ActionResult)

    // Animation directives
    case animationRequested(AnimationDirective)
}

// Bus protocol — each applet subscribes to events it cares about
protocol SuperEventBus {
    func publish(_ event: SuperEvent)
    func subscribe(to filter: EventFilter) -> AsyncStream<SuperEvent>
}
```

**Flow Example — "Add a todo via AI":**
1. User types: "Add a task to buy groceries, high priority, due tomorrow"
2. Chat sends message to Claude API with todo tools available
3. Claude responds with `tool_use: todo.create(title: "Buy groceries", priority: .high, due: "2026-03-14")`
4. Chat executes the tool call → creates the Todo via ToDo's service layer
5. ToDo's service publishes `SuperEvent.todoCreated(todo)`
6. Chat publishes `SuperEvent.animationRequested(.todoMaterialize(todo, from: .chatBubble))`
7. The animation engine picks up the directive and orchestrates:
   - In the chat: an "action card" appears confirming the creation
   - If the todo list is visible (split view on iPad/Mac): the new item animates in with a highlight effect
   - The todo tab badge increments with a bounce animation

---

## 6. Animation System

### 6.1 Animation Engine Architecture

The animation engine is a shared service that interprets `AnimationDirective` events and coordinates animations across applet boundaries.

```swift
struct AnimationDirective {
    let id: UUID
    let type: AnimationType
    let source: AppletIdentifier    // where the action originated
    let target: AppletIdentifier    // where the result should animate
    let payload: AnimationPayload   // applet-specific data for rendering
    let timing: AnimationTiming     // duration, delay, curve
}

enum AnimationType {
    case materialize    // item appears (todo created, event added)
    case transform      // item changes (status update, temperature change)
    case transfer       // item moves between applets (todo → calendar)
    case dismiss        // item disappears (todo completed, event cancelled)
    case pulse          // attention draw (device state change)
}
```

### 6.2 Cross-Applet Animation Strategy

**Same-screen animations (split view / iPad / Mac):**
- Use SwiftUI `matchedGeometryEffect` with a shared namespace across applet views
- Items can visually "fly" from one applet's view to another
- Requires a shared `@Namespace` at the Super container level

**Tab-based animations (iPhone):**
- Since applets are on different tabs, cross-applet animations use:
  - An overlay layer at the app container level for "flying" items
  - Tab bar badge animations (bounce, glow) to indicate changes in other applets
  - When switching to the target tab, the new item highlights briefly

### 6.3 Key Animation Moments

| Trigger | Animation | Notes |
|---------|-----------|-------|
| AI creates todo | Card materializes in chat → flies to todo list (if visible) or tab badge bounces | Signature interaction |
| AI creates calendar event | Event card in chat → drops into calendar time slot | Must handle off-screen time slots gracefully |
| AI changes home device | Device tile pulses / transforms (dial rotates, light changes color) | Real-time feel |
| Todo status change | Card slides between Kanban columns with spring physics | Direct manipulation feel |
| Todo completed | Satisfying checkmark animation + card shrinks away | Reward moment |
| Scene activated | Room tiles ripple-update as devices change state | Cascade effect |

---

## 7. Data Architecture

### 7.1 Local Data Layer

**GRDB** (SQLite-based, struct-based persistence) is the primary local store.

Each applet owns its own GRDB `DatabaseQueue` with its own `.sqlite` database file:
- **Chat:** `Conversation`, `Message`, `ToolCall`
- **Calendar:** `CalendarEvent`, `Recurrence`, `Reminder` (+ EventKit bridge)
- **ToDo:** `Project`, `Task`, `Subtask`, `Label`
- **Home:** `Room`, `Device`, `Scene`, `Automation` (+ HomeKit bridge)

Separate database files ensure applet independence and prevent schema conflicts.

### 7.2 Sync Strategy

**Phase 1 (Launch):** Local-only with per-applet GRDB databases
**Phase 2:** Custom platform-agnostic sync via backend (Postgres)

### 7.3 AI Conversation Data

- Conversations stored locally in GRDB
- Messages include both user text and AI responses (including tool calls and results)
- Conversation context sent to Claude API on each turn (sliding window for token management)
- No server-side storage of conversations (privacy-first)

---

## 8. Security Architecture

### 8.1 Data Security
- **Encryption at rest:** SQLite databases encrypted via iOS/macOS Data Protection (NSFileProtectionComplete)
- **Keychain:** API keys (Claude, any third-party integrations) stored in Keychain, never in UserDefaults or plaintext
- **Network:** All API calls over HTTPS/TLS 1.3

### 8.2 AI Security
- **API key protection:** Claude API key stored on backend; client never directly calls Claude API. Backend proxies all LLM requests.
- **Prompt injection defense:** Tool calls are validated server-side before execution. The AI cannot perform actions outside its defined tool set.
- **Rate limiting:** Backend enforces per-user rate limits on AI requests
- **Content filtering:** Backend can implement content filtering on AI inputs/outputs if needed

### 8.3 Home Automation Security
- **HomeKit handles security:** Apple's HomeKit framework manages device authentication and encryption
- **No credentials on server:** Home device credentials never leave the device
- **Action confirmation:** Destructive home actions (lock/unlock doors, disable security) require explicit user confirmation even when initiated by AI
- **Audit log:** All AI-initiated home actions are logged locally

### 8.4 Authentication
- **Username/password authentication** for simplicity and self-hosting compatibility (see [AUTH.md](./AUTH.md))
- **Backend auth:** JWT tokens with short expiry + refresh tokens
- **Biometric unlock:** Face ID / Touch ID for app access (optional, user-configurable)

---

## 9. Project Structure (Monorepo)

```
Super/
├── docs/                           # Product & architecture docs
│   ├── PRODUCT_VISION.md          # This document
│   ├── CHAT_SPEC.md           # AI Chatbot detailed spec
│   ├── CALENDAR_SPEC.md             # Calendar detailed spec
│   ├── TODO_SPEC.md              # Todo list detailed spec
│   ├── HOME_SPEC.md            # Home assistant detailed spec
│   ├── MOBILE_ARCHITECTURE.md     # Mobile/client-side architecture
│   ├── SERVER_ARCHITECTURE.md     # Server/backend architecture
│   ├── CLIENT_SERVER.md           # Client-server communication
│   ├── AUTH.md                    # Authentication (username/password, JWT)
│   └── SECURITY.md                # Security model & threat analysis
│
├── SuperApp/                    # Xcode project root
│   ├── Super/                   # Main app target
│   │   ├── App/                    # App entry point, navigation, DI
│   │   ├── Shared/                 # Shared UI components, design system
│   │   └── AnimationEngine/        # Cross-applet animation system
│   │
│   ├── Modules/                    # Feature modules (Swift Packages)
│   │   ├── Chat/               # AI Chatbot module
│   │   │   ├── Sources/
│   │   │   │   ├── UI/             # SwiftUI views
│   │   │   │   ├── Domain/         # Business logic, use cases
│   │   │   │   ├── Data/           # GRDB models, repositories
│   │   │   │   └── Service/        # Claude API client, tool registry
│   │   │   └── Tests/
│   │   ├── Calendar/                 # Calendar module
│   │   ├── ToDo/                  # Todo module
│   │   └── Home/                # Home Assistant module
│   │
│   ├── Core/                       # Shared Swift Package
│   │   ├── EventBus/               # SuperEvent bus
│   │   ├── Networking/             # HTTP client, auth
│   │   ├── Storage/                # GRDB / SQLite helpers
│   │   └── DesignSystem/           # Colors, typography, shared components
│   │
│   └── Super.xcodeproj
│
├── super-server/                # Backend
│   ├── src/
│   │   ├── gateway/
│   │   ├── modules/
│   │   │   ├── ai/
│   │   │   ├── calendar/
│   │   │   ├── todos/
│   │   │   └── home/
│   │   └── shared/
│   ├── package.json
│   └── tsconfig.json
│
└── README.md
```

**Why Swift Packages for modules:** Each module is a Swift Package within the monorepo. This enforces compile-time module boundaries (a module literally cannot import another module's internals), enables independent testing, and makes it trivial to extract a module into a standalone app later.

---

## 10. Development Phases

### Phase 1: Foundation (Weeks 1-3)
- [ ] Set up monorepo with Xcode project and Swift Package structure
- [ ] Implement Core package: EventBus, Networking, Storage, DesignSystem
- [ ] Build app shell with tab navigation (iOS) and sidebar navigation (macOS)
- [ ] Set up backend project with auth and API gateway
- [ ] Implement username/password authentication flow (see [AUTH.md](./AUTH.md))

### Phase 2: Chat — AI Chatbot (Weeks 3-5)
- [ ] Chat UI with message bubbles, streaming text rendering
- [ ] Claude API integration via backend proxy
- [ ] Tool/function calling framework (tool registry, execution, response rendering)
- [ ] Conversation persistence (GRDB)
- [ ] Action card UI components for tool results
- [ ] Voice input/output

### Phase 3: ToDo — Todo List (Weeks 5-7)
- [ ] Data model: Projects, Tasks, Subtasks, Labels
- [ ] List view and Kanban board view
- [ ] Task CRUD with animations
- [ ] Register todo tools with Chat
- [ ] Cross-applet animation: AI creates todo → visual feedback
- [ ] Custom sync infrastructure

### Phase 4: Calendar — Calendar (Weeks 7-9)
- [ ] Day / Week / Month views with animated transitions
- [ ] Event CRUD
- [ ] EventKit integration (system calendar sync)
- [ ] Register calendar tools with Chat
- [ ] Cross-applet: todo due dates appear on calendar
- [ ] Cross-applet animation: AI creates event → visual feedback

### Phase 5: Home — Home Assistant (Weeks 9-11)
- [ ] HomeKit integration (HMHomeManager)
- [ ] Room-based device grid UI
- [ ] Device control (lights, thermostat, locks)
- [ ] Scene management
- [ ] Register home tools with Chat
- [ ] Cross-applet animation: AI controls device → visual feedback

### Phase 6: Polish & Integration (Weeks 11-13)
- [ ] Cross-applet animation refinement
- [ ] iPad and macOS layout optimization (split views, sidebars)
- [ ] Performance profiling and optimization
- [ ] Accessibility audit (VoiceOver, Dynamic Type)
- [ ] Error handling and edge cases
- [ ] Beta testing

---

## 11. Open Questions & Future Considerations

### Open Questions
1. **Monetization model?** Free with limits? Subscription for AI usage? One-time purchase?
2. **Collaboration features?** Shared todo lists, shared calendars — adds significant complexity (real-time sync, conflict resolution, permissions)
3. **Widget support?** iOS widgets for quick glance at todos, upcoming events, home status
4. **Siri integration?** Register Siri Shortcuts / App Intents for system-level voice control
5. **Apple Intelligence integration?** Leverage on-device Apple Intelligence features as they mature

### Planned Future Applets (Influence Architecture Now)

These applets are not in scope for v1 but are *expected* additions. The architecture must accommodate them without rearchitecting. They should be considered when designing the applet protocol, event bus, and navigation shell.

- **Notifications (Notifications Hub):** A centralized notification inbox that aggregates actionable notifications from all applets. Each applet pushes notifications to Notifications via the event bus. Notifications categorizes, prioritizes, and surfaces items that need user attention. This applet influences how the shell routes notifications (system push vs. in-app) and how applets declare notification types.
- **Open Claw Integration in Chat:** The AI chatbot should support connecting to Open Claw as an LLM provider (alongside Claude). This means Chat's LLM adapter layer must be provider-agnostic from day one — swappable model backends with a unified tool-calling interface. Open Claw may have different tool-calling conventions that the adapter needs to normalize.
- **Money (Personal Finance):** An all-in-one finance applet powered by Plaid integrations. Aggregates bank accounts, credit cards, and investment accounts into a unified view. Core capabilities: real-time balances, transaction history with search/sort/filter, custom transaction tagging and categorization, income tracking, investment performance charting, spending breakdowns by category/merchant/time period. Integrates with Chat so users can ask "how much did I spend on groceries this month?" or "tag all Uber transactions as commute." Super is intended to be open source — developers bring their own Plaid API key (BYOK model). This applet influences architecture in several ways: (1) the backend needs a Plaid integration module with webhook support for real-time transaction updates, (2) the sync mechanism needs to handle high-volume transaction data efficiently, (3) Money data could feed into Calendar (bill due dates) and ToDo (financial to-dos like "pay rent"). Security details deferred until implementation — see SECURITY.md Section 6.5.

### Additional Future Applet Ideas
- **Fitness:** Health & fitness tracking (HealthKit integration)
- **Notes:** Note-taking with AI summarization
- **Habit:** Habit tracker with streaks and analytics

### Technical Debt to Watch
- Animation complexity budget: don't let cross-applet animations become so complex they cause frame drops
- GRDB migration management: maintain disciplined schema versioning as applet models evolve
- Claude API costs: implement smart context management to minimize token usage

---

## 12. Success Metrics

| Metric | Target | Why It Matters |
|--------|--------|----------------|
| AI action success rate | >95% | Tool calls should reliably complete the intended action |
| Cross-applet animation frame rate | 60fps | Animations are the product identity; jank kills the experience |
| App launch to interaction | <1s | Personal tool must feel instant |
| Offline functionality | 100% | Users should never be blocked by connectivity — including AI chat via on-device models |
| Crash-free rate | >99.5% | Trust is built through reliability |

---

## 13. Document Index

This product vision will be decomposed into the following detailed specification documents:

| Document | Scope | Status |
|----------|-------|--------|
| `PRODUCT_VISION.md` | Overall vision, architecture, decisions (this doc) | Draft |
| `DESIGN.md` | App shell, applet system, navigation, adding/removing applets | Draft |
| `CHAT_SPEC.md` | AI Chatbot detailed spec | Planned |
| `CALENDAR_SPEC.md` | Calendar detailed spec | Planned |
| `TODO_SPEC.md` | Todo list detailed spec | Planned |
| `HOME_SPEC.md` | Home assistant detailed spec | Planned |
| `AUTH.md` | Authentication — username/password, JWT tokens, admin account setup | Draft |
| `MOBILE_ARCHITECTURE.md` | Mobile architecture — shell, applets, event bus, tool system, data layer | Draft |
| `SERVER_ARCHITECTURE.md` | Server architecture — gateway, per-applet services, admin dashboard | Draft |
| `CLIENT_SERVER.md` | Client ↔ server communication — sync vs REST, routing, Chat orchestration | Draft |
| `SECURITY.md` | Security model, threat analysis, encryption, mitigations | Draft |
| `SYNC.md` | Platform-agnostic sync engine design (GRDB ↔ Postgres) | Draft |
| `CI_PIPELINE.md` | CI/CD pipeline, AI agent workflow, automated testing & review | Draft |
| `OBSERVABILITY.md` | Metrics, crash reporting, analytics, logging (client + server) | Draft |
| `ANIMATION_SYSTEM.md` | Animation engine design & cross-applet choreography | Planned |
| `CHAT_INTERACTIONS.md` | Cross-applet interaction catalog — 66 user stories, deep linking, response types | Draft |
| `AI_TOOLS.md` | AI development tools evaluation (Axiom, GSD, Context7) with security | Draft |
| `DEVELOPMENT_SETUP.md` | Clone, build, deploy, server first-run wizard, iOS setup, troubleshooting | Draft |
| `API_DESIGN.md` | Backend API contracts & AI tool definitions | Planned |
