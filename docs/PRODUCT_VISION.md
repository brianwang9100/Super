# Super: Product Vision & Architecture

> A chat-centric, AI-first productivity app with pluggable mini-apps. Chat is the primary surface; mini-apps live inside it and talk to it both ways.

> **Status (2026-05-10):** Vision doc — the full target. What ships today is the Chat applet on iOS only (MVP M0–M12 complete); mini-apps, the multi-state shell overlay, the server, and sync remain on the roadmap. See [`README.md`](../README.md), [`TODO.md`](../TODO.md), and the archived MVP build log at [`archived/IMPLEMENTATION_STATUS.md`](archived/IMPLEMENTATION_STATUS.md) for the up-to-date picture.

---

## 1. Executive Summary

Super is a native Apple platform application (iOS + macOS) that consolidates a handful of everyday personal tools — todos, recipes, bible reading, finance, and more — into a single **chat-first** shell. The center of the app is always the conversation. Mini-apps (ToDo, Recipes, Bible, Finance, …) plug into that conversation: the AI can drive them via tool calls, and they can pipe their own records back into the conversation on demand.

The defining experience is **bi-directional AI**:

- **Chat → mini-app.** The user asks the AI to do something ("add four tasks to my home-reno list"), and the result renders as a rich embedded card inside the chat while the corresponding records materialize in the mini-app behind it.
- **Mini-app → chat.** Any record the user sees in any mini-app — a task, a recipe, a bible verse, a transaction — can be long-pressed and piped into the current chat, or used to seed a brand-new one.

Chat is not a tab; it is the host. Mini-apps render **behind** the chat in three coordinated overlay states — expanded (full chat), semi-expanded (floating chat panel + composer over a visible mini-app), and minimized (a floating chat bubble). See [`DESIGN.md`](./DESIGN.md) §4 for the full state model.

---

## 2. Core Principles

### 2.1 Chat Is the Host
Chat is always present. Mini-apps are opened *into* Chat, not alongside it — they render behind a floating chat panel or a minimized bubble, so the conversation and the mini-app are never separated. This is not a traditional tab-bar app; it's a chat with mini-apps plugged into it.

### 2.2 Modularity First
Each mini-app (ToDo, Recipes, Bible, Finance, …) is a fully independent module with its own data layer, business logic, and UI. Mini-apps communicate exclusively through a well-defined event bus and the shared tool/chat-card registry. This enables:
- Independent development and testing of each mini-app
- One AI agent per mini-app during the build phase
- Future extensibility (add new mini-apps without touching existing ones)
- Each mini-app can ship as a standalone app if desired

### 2.3 Bi-Directional AI (The Signature Interaction)
The conversation and the mini-apps know about each other in both directions.

- **Chat → mini-app:** the AI calls a mini-app's tool; a rich chat card (rendered by the mini-app itself) appears inline, and the corresponding record materializes in the mini-app's view behind the chat. Chat messages can reference specific records ("…Revelation 3:20 says…"); tapping the reference deep-links straight into that record in the mini-app.
- **Mini-app → chat:** long-press any record in any mini-app to open a focused action sheet that always includes **Add to current chat** and **Start new chat with this**. A verse, a task, a recipe, a transaction — all of them can be piped into the conversation as structured references (never copy-pasted text), so the AI can act on the real record.

Bi-directional AI is the primary product differentiator. Every mini-app MUST implement both directions; a mini-app that only surfaces data isn't done.

### 2.4 AI as Orchestrator, Not Gatekeeper
The AI is the orchestration layer but never the *only* way to interact. Every action the AI can perform is also available through direct UI inside the mini-app. The AI adds convenience and cross-mini-app coordination — it does not gatekeep functionality.

### 2.5 Design-First: Clean, Animated, Responsive
Super is unapologetically design-oriented. Three rules, enforced everywhere:

- **Hide until expanded.** Assistant thinking, tool calls, record details, focused-view actions — all collapsed by default, one tap to reveal. No cluttered dashboards.
- **Animate the causality.** Every AI action is accompanied by a materialize/transfer/pulse animation that ties the chat card to the record in the mini-app, so the user *sees* cause and effect.
- **Responsive over dense.** Wide whitespace, generous touch targets, "study bible" palettes (Vellum / Lapis / Scriptorium / Slate), EB Garamond display + Geist body. Information appears when asked for; the UI is quiet otherwise.

### 2.6 Offline-First

The app must work without a network — on a plane, in a subway, anywhere. This is a non-negotiable constraint, not a nice-to-have.

- **Data is on-device first.** GRDB/SQLite is the local source of truth. Cloud sync is additive — replication and backup, never a runtime dependency.
- **LLMs run locally when possible.** On-device models (MLX, Apple Foundation Models) are the preferred configuration. Cloud LLM providers (OpenAI-compatible endpoints including Claude) are supported but optional. Chat must function with a local model alone.
- **Tools default to local execution.** Each AI tool runs on-device unless it genuinely requires network (e.g., a Finance Plaid refresh, a remote MCP server). Local vs. remote is a per-tool decision, not a per-mini-app one; a single mini-app may mix both.
- **Graceful degradation, not failure.** When a feature genuinely needs network and network is unavailable, the UI says so. Nothing else breaks.

The only features that inherently require connectivity are: remote tool calls (by definition), multi-device sync, and cloud LLM providers when selected. Everything else — including AI chat with a local model — works offline.

### 2.7 Privacy by Default
Personal productivity data is sensitive. All data at rest is encrypted. Third-party mini-app credentials (Plaid, etc.) never leave the device. LLM interactions are stateless on the server side — no conversation history is stored remotely unless the user opts in.

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

Chat is the host (§4.1). The launch mini-app set is ToDo, Recipes, Bible, and Finance (§4.2–§4.5). Calendar, Home, and others are in [§11 Planned Future Applets](#11-open-questions--future-considerations).

Every mini-app MUST implement the bi-directional contract:

1. **Tool calls** — expose CRUD and query operations to Chat via `ToolRegistration`.
2. **Chat card renderers** — render rich inline cards for tool results (single-record, batch, confirmation) using the mini-app's own SwiftUI.
3. **Record actions** — on long-press, expose its domain actions plus the shell-provided **Add to current chat** and **Start new chat with this**.
4. **Deep-link targets** — accept `super://<appletId>/<recordId>` routing so chat references become tappable.

### 4.1 Chat — The Host Surface

**Purpose:** Natural language interface, orchestrator, and the host surface for every other mini-app.

**Core Capabilities:**
- Conversational AI via any OpenAI-compatible endpoint (BYOK)
- Streaming responses with real-time token rendering
- Thinking / tool-call / code blocks, all collapsible by verbosity
- Multiple concurrent chats; per-chat model selection
- Context-aware: the AI sees which mini-apps are installed and what tools they expose
- Voice input (Speech-to-text) — ships as a visual affordance in MVP
- Three overlay states: expanded / floating-over-mini-app / minimized bubble (see [`DESIGN.md`](./DESIGN.md) §4)

**Key UX Details:**
- Assistant messages are bubble-less (bare text); user messages are pastel-green bubbles
- Rich embedded cards rendered by mini-apps when their tools are invoked
- Verbosity pill: Simple (blocks collapsed) / Thinking (thinking expanded) / Verbose (everything expanded)
- Full Chat UI spec in [`Chat/DESIGN.md`](./Chat/DESIGN.md)

**Tool/Function Calling Architecture:**
Every installed mini-app auto-registers its tools with Chat at startup. Example tools across the launch set:

```
todo.create(title, description?, priority?, dueDate?, listId?)
todo.createMany([{title, priority, …}])
todo.update(id, fields…)
todo.list(filter?)

recipe.save(title, ingredients, steps, source?)
recipe.search(query)
recipe.scale(id, factor)

bible.lookup(action, references?, query?, translation?)  // action:"read" → passages (e.g. "Rev 3:20"); "search" → topical verses
bible.highlight(reference, color)

finance.listTransactions(range, filter?)
finance.tagTransactions([ids], tag)
finance.spendByCategory(range)
```

**AI Model Choice:** OpenAI-compatible endpoints (Opus 4.7, GPT 5.5, Qwen3.6, Gemma 4 in MVP; users add more). The architecture is provider-agnostic through an adapter layer so local and remote models are interchangeable per chat.

---

### 4.2 ToDo

**Purpose:** Linear/Jira-style task management for personal use, with AI-driven creation and triage.

**Core Capabilities:**
- Projects (lists), tasks, and subtasks with hierarchy
- Status workflow: Backlog → Todo → In Progress → Done → Archived
- Priority levels (Urgent, High, Medium, Low) with visual indicators
- Labels / tags, due dates, sort and filter
- List view and Kanban board view
- AI-powered: natural-language creation, batch creation, breakdown, priority suggestion

**Chat Cards:** single-task, batch (N-task mini-list), reschedule confirmation, completion summary.

**Long-press Actions:** Edit, Change priority, Reschedule, Delete, **Add to current chat**, **Start new chat with this**.

**Key UX Details:**
- AI-created tasks materialize into the list with a spring when ToDo is visible behind the chat
- Swipe to complete; drag between Kanban columns
- Badge count on the sidebar row for overdue/urgent tasks

**Data Model:** GRDB structs — `Project`, `Task`, `Subtask`, `Label`. Custom backend sync.

---

### 4.3 Recipes

**Purpose:** Personal recipe collection with AI-assisted capture, substitution, scaling, and cooking.

**Core Capabilities:**
- Save recipes from plain text, URL, or dictation
- Ingredient list with unit parsing; step-by-step instructions
- Scaling (1× → 2×, adjusts ingredients + cookware recommendations via AI)
- Timers launched inline (each timer is a record; triggers a system notification when done)
- Collections / tags (Weeknight, Holiday, Vegetarian, …)
- AI-powered: substitutions ("I'm out of crushed tomatoes"), ingredient-based search ("what can I make with snow pea leaves?"), scaling, cook-along narration

**Chat Cards:** recipe summary (title + hero image + quick-read ingredient list), timer card, substitution suggestion.

**Long-press Actions:** Edit, Scale, Start timer, Export, Delete, **Add to current chat**, **Start new chat with this**.

**Key UX Details:**
- Cook mode: step-by-step with large text and voice advance; the chat bubble stays available for hands-free Q&A
- AI-saved recipes animate into the collection grid

**Data Model:** GRDB structs — `Recipe`, `Ingredient`, `Step`, `Timer`, `Collection`.

---

### 4.4 Bible

**Purpose:** Reading, searching, highlighting, and conversing with scripture.

> **Shared between SuperOS and SuperBible.** The Bible package is the centerpiece of the SuperBible app (the public App Store target — see §13) and a member of SuperOS's broader applet set. Same code, same data model, same bi-directional contract.

**Core Capabilities:**
- Multiple translations (user-selectable, BYO if not bundled)
- Reading view with chapter navigation, daily reading plans
- Highlights + notes per verse range, synced locally
- Search across translations
- Deep-linkable references (e.g., `super://bible/rev.3.20`)
- AI-powered: explain a passage, cross-references, summarize a chapter, "where does it say X?"

**Chat Cards:** passage preview (reference + inline verses), cross-reference list, highlight confirmation.

**Long-press Actions (on a verse or selection):** Highlight (color picker), Add note, Copy, Share, **Add to current chat**, **Start new chat with this**.

**Key UX Details:**
- Dismissing verse actions keeps the verses selected and the sheet closed while the selection is edited. Tap the top selection pill to reopen actions, or its × button to clear the selection. Tapping empty reader space dismisses the actions without clearing the verses.
- Chat messages that contain a canonical reference ("Revelation 3:20") render the reference as a tappable inline token; tapping deep-links into the Bible mini-app (state A → B) and scrolls to the verse
- Highlighting in the Bible view fires an event so Chat can reference "the verse you highlighted earlier"

**Data Model:** GRDB structs — `Translation`, `Book`, `Chapter`, `Verse`, `Highlight`, `Note`, `ReadingPlan`.

---

### 4.5 Finance

**Purpose:** Personal finance aggregator — bank, card, and investment accounts in one view, AI-queryable.

**Core Capabilities:**
- Plaid integration for real-time balances and transactions (BYOK — user's Plaid key)
- Transaction list with search, sort, filter, custom tags
- Spending breakdowns by category / merchant / time period
- Income tracking, investment performance charts
- AI-powered: "how much did I spend on groceries this month?", "tag all Uber transactions as commute," "find unusual charges this week"

**Chat Cards:** transaction summary, spending-by-category chart, tag-confirmation card, account balance card.

**Long-press Actions (on a transaction):** Retag, Split, Hide, Mark as reviewed, **Add to current chat**, **Start new chat with this**.

**Key UX Details:**
- Tables with live sort, persisted filters, sparkline totals
- Sensitive figures respect a "private mode" toggle (numbers blurred until tapped)

**Data Model:** GRDB structs — `Account`, `Transaction`, `Category`, `Tag`, `Rule`. Server-side Plaid webhook handler for real-time updates. See `SECURITY.md` §6.5 for key handling.

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
    // Per-applet record lifecycle (generic payload — shell doesn't know domain types)
    case recordCreated(appletId: String, recordId: String, kind: String, summary: String)
    case recordUpdated(appletId: String, recordId: String, kind: String, changes: [String: Any])
    case recordDeleted(appletId: String, recordId: String, kind: String)

    // Mini-app → Chat (user piping a record into a chat)
    case recordAddedToChat(ref: RecordRef, chatId: String)
    case recordSeededNewChat(ref: RecordRef, newChatId: String)

    // Chat → Mini-app (deep link from a chat card or inline reference)
    case deepLinkRequested(ref: RecordRef, source: DeepLinkSource)

    // AI lifecycle
    case aiActionStarted(AIAction)
    case aiActionCompleted(AIAction, result: ActionResult)

    // Animation directives
    case animationRequested(AnimationDirective)
}

// A record is always referred to by this lightweight tuple on the bus,
// never by its full domain type — keeps the bus decoupled from mini-apps.
struct RecordRef: Codable, Sendable {
    let appletId: String          // "todo", "bible", "recipe", "finance"
    let kind: String              // "task", "verse", "recipe", "transaction"
    let id: String                // mini-app-local record id
    let displayTitle: String
    let previewText: String?
}

// Bus protocol — each mini-app subscribes to events it cares about
protocol SuperEventBus {
    func publish(_ event: SuperEvent)
    func subscribe(to filter: EventFilter) -> AsyncStream<SuperEvent>
}
```

**Flow Example A — Chat creates a batch of tasks (Chat → mini-app):**
1. User (in State A — expanded chat): "Add four tasks for my home reno: paint bedroom, fix kitchen faucet, replace bathroom mirror, install new light fixtures."
2. Chat streams the response; the AI emits `todo.createMany([…])` as a tool call.
3. Chat invokes ToDo's tool handler → ToDo inserts four rows, publishes four `recordCreated` events.
4. ToDo's registered chat-card renderer for `batch-summary` returns a SwiftUI card containing a mini-list of the four tasks; Chat inlines the card in the assistant message.
5. If ToDo is visible behind the chat (State B), the four rows materialize into the list with a stagger.
6. Tapping "View in ToDo" on the card fires `deepLinkRequested(ref: …, source: .chatCard)`; the shell transitions A → B, pushes ToDo behind the chat, scrolls/selects the first task.

**Flow Example B — User pipes a Bible verse into chat (mini-app → Chat):**
1. User (in State B — Bible visible, floating chat) long-presses Revelation 3:20.
2. Focused view shows Bible-specific actions plus **Add to current chat** / **Start new chat with this**.
3. User taps Add to current chat → Bible publishes `recordAddedToChat(ref: {appletId:"bible", kind:"verse", id:"rev.3.20", …})`.
4. Chat inserts a user message whose payload is the ref (not the verse text); the UI renders it as a compact verse chip.
5. The AI receives the ref on the next turn and can resolve the full passage through `bible.lookup("rev.3.20")` when needed — no copy-paste of text into the context window.

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

### 6.2 Animation Strategy Across Chat Overlay States

Animations work differently depending on which chat overlay state is active (A/B/C — see [`DESIGN.md`](./DESIGN.md) §4).

**State B — mini-app visible behind floating chat (the signature case):**
- Use SwiftUI `matchedGeometryEffect` in a namespace shared by the chat-card layer and the mini-app view
- The chat card for a newly-created record can visually "emit" the record into the mini-app's list with a stagger
- The mini-app's own row-insert animation takes over once the record arrives

**State A — expanded chat (no mini-app visible):**
- No cross-view animation is possible; the chat card simply fades in
- If the user then deep-links into the mini-app, the shell plays a deferred "highlight-on-arrival" on the referenced record

**State C — chat minimized to bubble:**
- Chat-card events can't animate (the card is off-screen); the bubble pulses accent once to signal a new message
- The mini-app's own record-insert animation still runs as normal

### 6.3 Key Animation Moments

| Trigger | Animation | Notes |
|---------|-----------|-------|
| AI creates a todo / batch of todos | Card materializes in chat → (State B) records stagger into the list with matched geometry; (State A) card fades in, highlight-on-arrival when deep-linked | Signature interaction |
| AI saves a recipe | Recipe card fades into chat → collection grid tile pulses in | State B: visible; State C: bubble pulse only |
| AI looks up a Bible verse | Passage card in chat → tappable reference token; tapping transitions A/C → B and scrolls to the verse with a highlight | Deep-link choreography |
| AI tags finance transactions | Tag card in chat with affected count → in State B, matching rows flash their new tag | Batch confirmation |
| User long-presses a record | Focused action sheet scales in with blurred backdrop | Shared across all mini-apps |
| User adds record to chat | Record chip slides up from the focused sheet into the chat's message list | Mini-app → Chat direction |
| State A ↔ B transition | Mini-app crossfades; chat panel springs between full-screen and floating panel | Respect Reduce Motion |
| State B ↔ C transition | Panel + composer slide down; bubble scales up from bottom-right corner | 300ms spring |
| Todo completed | Checkmark spring + row shrinks away | Reward moment |
| Mini-app install | Sidebar row spring-scales up from 0 | System default spring |

---

## 7. Data Architecture

### 7.1 Local Data Layer

**GRDB** (SQLite-based, struct-based persistence) is the primary local store.

Each mini-app owns its own GRDB `DatabaseQueue` with its own `.sqlite` database file:
- **Chat:** `Conversation`, `Message`, `MessagePart`, `ToolCall`, `RecordRef`
- **ToDo:** `Project`, `Task`, `Subtask`, `Label`
- **Recipes:** `Recipe`, `Ingredient`, `Step`, `Timer`, `Collection`
- **Bible:** `Translation`, `Book`, `Chapter`, `Verse`, `Highlight`, `Note`, `ReadingPlan`
- **Finance:** `Account`, `Transaction`, `Category`, `Tag`, `Rule`

Separate database files ensure mini-app independence and prevent schema conflicts.

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
│   ├── DESIGN.md                  # Shell — chat overlay states, mini-app plug-in
│   ├── Chat/                      # Chat host: DESIGN.md + ARCHITECTURE.md
│   ├── Todo/                      # (planned) Todo mini-app docs
│   ├── Recipes/                   # (planned) Recipes mini-app docs
│   ├── Bible/                     # (planned) Bible mini-app docs
│   ├── Finance/                   # (planned) Finance mini-app docs
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
│   │   ├── Chat/                   # Chat — the host surface
│   │   │   ├── Sources/
│   │   │   │   ├── UI/             # SwiftUI views (3 overlay states, composer, sidebar)
│   │   │   │   ├── Domain/         # Business logic, use cases
│   │   │   │   ├── Data/           # GRDB models, repositories
│   │   │   │   └── Service/        # LLM client, tool registry, chat-card registry
│   │   │   └── Tests/
│   │   ├── ToDo/                   # Todo mini-app
│   │   ├── Recipes/                # Recipes mini-app
│   │   ├── Bible/                  # Bible mini-app
│   │   └── Finance/                # Finance mini-app
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
│   │   │   ├── todos/
│   │   │   ├── recipes/
│   │   │   ├── bible/
│   │   │   └── finance/
│   │   └── shared/
│   ├── package.json
│   └── tsconfig.json
│
└── README.md
```

**Why Swift Packages for modules:** Each module is a Swift Package within the monorepo. This enforces compile-time module boundaries (a module literally cannot import another module's internals), enables independent testing, and makes it trivial to extract a module into a standalone app later.

---

## 10. Development Phases

### Phase 1: Foundation
- [ ] Monorepo + Xcode project + Swift Package structure
- [ ] Core package: EventBus, Networking, Storage, DesignSystem (study-bible theme tokens, EB Garamond / Geist / JetBrains Mono)
- [ ] App shell with the sidebar and the three chat overlay states (placeholder mini-app behind the chat)
- [ ] Backend project with auth and API gateway
- [ ] Username/password authentication (see [AUTH.md](./AUTH.md))

### Phase 2: Chat — Expanded State (the MVP surface)
- [ ] Expanded chat UI matching [`Chat/DESIGN.md`](./Chat/DESIGN.md): composer pill, model pill, context meter, send/mic (verbosity lives in Settings → Default Verbosity)
- [ ] OpenAI-compatible streaming client (BYOK, per-chat model selection)
- [ ] Tool-call framework: `ToolRegistration`, registry, execution, streaming tool_call delta accumulation
- [ ] Chat-card registry: mini-apps register renderers by `{appletId, cardKind}`
- [ ] Conversation + message-parts persistence (GRDB), concurrent chats
- [ ] Sidebar: wordmark, applets list, CHATS with running spinners, profile + settings gear
- [ ] Settings: Models, Theme, System Prompt, Default Verbosity, Appearance, Data, About
- [ ] Deep-link router: `super://<applet>/<recordId>`

### Phase 3: Chat — Overlay States B & C
- [ ] Floating chat panel + floating composer over a mini-app (State B)
- [ ] Minimized bubble (State C) with drag-to-reposition, unread pulse, typing-fade
- [ ] A↔B↔C spring transitions with matched geometry; Reduce Motion fallback
- [ ] iPad and macOS adaptations (persistent sidebar, right-side panel, window-bound bubble)

### Phase 4: ToDo (First Mini-App — exercises the full bi-directional contract)
- [ ] Data model: Projects, Tasks, Subtasks, Labels
- [ ] List + Kanban views
- [ ] Register todo tools with Chat (create/createMany/update/list/complete)
- [ ] Chat-card renderers: single-task, batch summary, completion summary
- [ ] Long-press focused view with **Add to current chat** / **Start new chat with this**
- [ ] Chat-card → materialize animation when ToDo is visible behind the chat (State B)
- [ ] Custom sync infrastructure

### Phase 5: Recipes
- [ ] Data model: Recipe, Ingredient, Step, Timer, Collection
- [ ] Capture from text/URL/dictation, scaling, timers
- [ ] Tools: save, search, scale, startTimer, substitute
- [ ] Chat cards: recipe summary, timer, substitution suggestion
- [ ] Long-press focused view with shell-provided chat actions
- [ ] Cook mode (hands-free, chat bubble stays available)

### Phase 6: Bible
- [ ] Data model: Translation, Book, Chapter, Verse, Highlight, Note, ReadingPlan
- [ ] Reading view, search, highlights, notes, reading plans
- [ ] Tools: lookup, search, highlight, crossReferences
- [ ] Chat cards: passage preview, cross-reference list
- [ ] Inline canonical-reference tokens in chat messages (tappable → deep link)
- [ ] Long-press verse selection → shell chat actions

### Phase 7: Finance
- [ ] Data model: Account, Transaction, Category, Tag, Rule
- [ ] Plaid integration (BYOK), webhook-driven updates via server
- [ ] Transaction list with filters, tags, breakdowns
- [ ] Tools: listTransactions, tag, spendByCategory, accountBalance
- [ ] Chat cards: transaction summary, spending chart, tag-confirmation
- [ ] Private mode (blurred numbers)

### Phase 8: Polish & Integration
- [ ] Cross-mini-app animation refinement (matched geometry across chat cards ↔ mini-apps)
- [ ] Performance profiling; 60fps on all three overlay states
- [ ] Accessibility audit (VoiceOver, Dynamic Type, Reduce Motion across states)
- [ ] Error handling and edge cases
- [ ] Beta testing

---

## 11. Open Questions & Future Considerations

### Open Questions
1. ~~**Monetization model?** Free with limits? Subscription for AI usage? One-time purchase?~~ **Resolved (2026-05-23):** SuperBible (App Store target) ships free, BYOK, no ads, no IAP, no premium tier, with an optional GitHub Sponsors link in Settings → About. SuperOS is the founder's personal app and has no monetization surface. See [`superpowers/specs/2026-05-23-superbible-fork-design.md`](./superpowers/specs/2026-05-23-superbible-fork-design.md) §6.
2. **Collaboration features?** Shared todo lists, shared bible study notes — adds significant complexity (real-time sync, conflict resolution, permissions)
3. **Widget support?** iOS widgets for quick glance at todos and finance summaries
4. **Siri integration?** Register Siri Shortcuts / App Intents for system-level voice control
5. **Apple Intelligence integration?** Leverage on-device Apple Intelligence features as they mature

### Planned Future Mini-Apps (Influence Architecture Now)

These mini-apps are not in scope for v1 but are *expected* additions. The architecture must accommodate them — same bi-directional contract, same plug-in protocol — without rearchitecting.

- **Notifications Hub:** A centralized notification inbox aggregating actionable notifications from every mini-app. Receives `recordCreated` / `recordUpdated` events via the bus, categorizes them, and surfaces items needing attention. Shapes how the shell routes system push vs. in-app notifications.
- **Calendar:** Day/Week/Month views, EventKit bridge, natural-language event creation, conflict detection. Feeds due dates from ToDo and bill dates from Finance into a unified timeline.
- **Home:** HomeKit / Matter device control and scenes. Destructive actions (unlock doors, disable security) require biometric confirmation even when initiated by AI. Needs an audit log.
- **Fitness:** HealthKit-backed tracking with AI summarization.
- **Notes:** Note-taking with AI summarization and long-press-to-chat.
- **Habit:** Habit tracker with streaks and analytics.

### Technical Debt to Watch
- Animation complexity across the three chat overlay states — don't let matched-geometry choreography drop frames
- GRDB migration management as each mini-app's schema evolves independently
- LLM token costs — keep system prompt + tool schemas compact, trim conversation history aggressively
- Chat-card registry blow-up — if every mini-app ships 10 card kinds, the registry and renderer resolution need to stay O(1)

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

## 13. App targets: SuperOS vs SuperBible

The Super monorepo ships **two distinct iOS apps** from a shared codebase:

| | **SuperOS** | **SuperBible** |
|---|---|---|
| **Audience** | Founder's personal use | Public, free, App Store |
| **Bundle ID** | `com.brianwang.Super` | `com.brianwang.SuperBible` |
| **App Store** | Not heading to the App Store | Public release |
| **Applet set** | Chat + Bible + Todo (+ future Recipes, Calendar, Finance, Home, …) | Chat + Bible + Plans (+ future Memorize, Quiz, Learn) |
| **Backend** | TypeScript + Hono + Drizzle + Postgres + Redis (per `SERVER_ARCHITECTURE.md`) | None. Local-only. CloudKit + Sign in with Apple as the v2 upgrade if traction warrants. |
| **Monetization** | None | Free, BYOK, no ads, no IAP. Optional GitHub Sponsors link. |

Both apps share the same `Core`, `Chat`, and `Bible` packages, plus the shared shell at `App/Shell/`. Each has its own composition root (`App-SuperOS/SuperOSApp.swift` and `App-SuperBible/SuperBibleApp.swift`) that registers a different applet set. Every architectural decision in this document — `MiniApplet` protocol, event bus, GRDB-per-applet, BYOK + AFM default, bi-directional AI contract — applies to both apps unchanged.

**Why two apps:** SuperOS is too diffuse to launch publicly; SuperBible is sharp, focused, and free. Splitting the targets keeps the founder's personal app evolving on its own roadmap while the public product gets shipped, reviewed, and improved against real user feedback.

Full rationale and milestone plan in [`superpowers/specs/2026-05-23-superbible-fork-design.md`](./superpowers/specs/2026-05-23-superbible-fork-design.md).

---

## 14. Document Index

This product vision will be decomposed into the following detailed specification documents:

| Document | Scope | Status |
|----------|-------|--------|
| `PRODUCT_VISION.md` | Overall vision, architecture, decisions (this doc) | Draft |
| `DESIGN.md` | Shell — chat overlay states, mini-app plug-in, bi-directional AI | Draft |
| `Chat/DESIGN.md` | Chat UI spec — expanded state (composer, messages, sidebar, settings) | Draft |
| `Chat/ARCHITECTURE.md` | Chat architecture — LLM client, tool registry, chat-card registry, persistence | Draft |
| `Todo/DESIGN.md` | Todo mini-app detailed spec | Planned |
| `Recipes/DESIGN.md` | Recipes mini-app detailed spec | Planned |
| `Bible/DESIGN.md` | Bible mini-app detailed spec | Planned |
| `Finance/DESIGN.md` | Finance mini-app detailed spec | Planned |
| `AUTH.md` | Authentication — username/password, JWT tokens, admin account setup | Draft |
| `MOBILE_ARCHITECTURE.md` | Mobile architecture — shell, applets, event bus, tool system, data layer | Draft |
| `SERVER_ARCHITECTURE.md` | Server architecture — gateway, per-applet services, admin dashboard | Draft |
| `CLIENT_SERVER.md` | Client ↔ server communication — sync vs REST, routing, Chat orchestration | Draft |
| `SECURITY.md` | Security model, threat analysis, encryption, mitigations | Draft |
| `SYNC.md` | Platform-agnostic sync engine design (GRDB ↔ Postgres) | Draft |
| `CI_PIPELINE.md` | CI/CD pipeline, AI agent workflow, automated testing & review | Draft |
| `OBSERVABILITY.md` | Metrics, crash reporting, analytics, logging (client + server) | Draft |
| `ANIMATION_SYSTEM.md` | Animation engine design & cross-mini-app choreography across chat overlay states | Planned |
| `CHAT_INTERACTIONS.md` | Cross-mini-app interaction catalog — user stories, deep linking, response types | Draft |
| `AI_TOOLS.md` | AI development tools evaluation (Axiom, GSD, Context7) with security | Draft |
| `DEVELOPMENT_SETUP.md` | Clone, build, deploy, server first-run wizard, iOS setup, troubleshooting | Draft |
| `API_DESIGN.md` | Backend API contracts & AI tool definitions | Planned |
| `SuperBible/OVERVIEW.md` | SuperBible app target — one-pager intro for contributors | Draft |
| `SuperBible/OBSERVABILITY.md` | SuperBible observability — Apple-built-in only, no third-party SDKs | Draft |
| `superpowers/specs/2026-05-23-superbible-fork-design.md` | SuperBible fork design — architecture, monetization, CI, cloud roadmap | Draft |
