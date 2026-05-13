# Super: Top-Level Design

> How the Super shell hosts Chat and its mini-apps, and how the three chat overlay states (expanded / floating / bubble) coordinate with the mini-app underneath.

> **Status (2026-05-10):** The Chat surface itself is built and the MVP is shipped (M0–M12 all complete, with M11 voice input verified on hardware 2026-05-10); the three-state overlay system, mini-app hosting, and `AppletManager` registry described below are not yet implemented — there's only one applet today, and the shell renders it full-screen. Tracked in [`TODO.md`](../TODO.md) § Shell.

---

## 1. Purpose of This Document

Super is a chat-centric productivity app: **Chat is the primary surface**, and a set of **mini-apps** (Todo, Recipes, Bible, Finance, …) plug into it. Users can interact with their data either by chatting with the AI or by going directly into a mini-app. This document covers the **shell** — the container that hosts the chat surface and the mini-apps — and focuses on:

- How Chat hosts mini-apps and how mini-apps are navigated to
- The three chat overlay states and the transitions between them
- How the AI performs bi-directional interactions with mini-apps (chat → mini-app, mini-app → chat)
- How mini-apps are added, removed, and reordered
- How the shell adapts across iPhone, iPad, and macOS
- How future mini-apps plug into the system without architectural changes

Mini-app-specific UI is out of scope here; each mini-app has its own design doc (e.g., [`Chat/DESIGN.md`](./Chat/DESIGN.md)).

---

## 2. The Shell Concept

Super is not a traditional tab-bar app. It's a **chat-first shell** where Chat is always present — either filling the screen, floating in a panel over a mini-app, or collapsed into a bubble — and mini-apps slide in **behind** the chat surface when selected.

The shell owns:

- **The chat surface** itself and its three overlay states (see §4)
- **Mini-app registry** (which mini-apps are installed and in what order)
- **Navigation** between mini-apps (via the sidebar) and between the chat states
- **Event bus** (bi-directional communication between Chat and mini-apps)
- **Tool registry** (Chat auto-discovers tools exposed by each installed mini-app)
- **Deep-link router** (chat messages can link into a specific mini-app record; long-press actions in mini-apps can link back into chat)
- **Animation coordinator** (the materialize / transfer / pulse choreography across chat and mini-apps)
- **Notification routing** (system push vs. in-app Notifications inbox)
- **Shared design system** (typography, pastel-green palette, common components)

The shell does NOT own any mini-app's internal UI, data model, or business logic, and never owns mini-app settings.

---

## 3. Mini-App Registry & Lifecycle

### 3.1 Mini-App Manifest

Every mini-app declares itself through a standard protocol:

```swift
protocol SuperApplet {
    /// Unique identifier for this mini-app
    static var appletId: String { get }

    /// Display metadata
    var displayName: String { get }
    var icon: Image { get }
    var accentColor: Color { get }    // used for iconography and inline cards

    /// The root view for this mini-app (renders behind chat)
    @ViewBuilder var rootView: some View { get }

    /// Tools this mini-app exposes to Chat (auto-registered on install)
    var registeredTools: [ToolRegistration] { get }

    /// In-chat preview/action cards this mini-app knows how to render
    /// (e.g., ToDo renders a "4 tasks created" card with a mini-list)
    var chatCardRenderers: [ChatCardRenderer] { get }

    /// Long-press / focused-view actions exposed on this mini-app's records
    /// (these are the "add to chat" / "start new chat with this" actions)
    var recordActions: [RecordActionHandler] { get }

    /// Events this mini-app publishes and subscribes to
    var publishedEvents: [SuperEvent.Type] { get }
    var subscribedEvents: [SuperEvent.Type] { get }

    /// Lifecycle
    func onActivate()    // called when mini-app becomes visible behind chat
    func onDeactivate()  // called when user returns to full-screen chat
    func onInstall()     // called when first added
    func onUninstall()   // called when removed — must clean up data
}
```

### 3.2 Adding a Mini-App

1. User opens **Settings → Mini-Apps** or taps the "+" row in the sidebar.
2. The Mini-App Manager shows **Installed** (with toggles + drag handles) and **Available** sections.
3. User taps "Add" on an available mini-app.
4. **Install animation:** the new entry drops into the sidebar list with a spring; Chat acknowledges inline ("Added Recipes — you can now ask me about recipes.").
5. `onInstall()` runs: creates the mini-app's SQLite file (GRDB), registers its tools with Chat, subscribes to the event bus, and registers its chat-card renderers and record-action handlers.
6. The mini-app is immediately selectable from the sidebar, and Chat immediately has access to its tools.

**No app restart.** The registry is `@Observable`; SwiftUI re-renders the sidebar when it changes.

### 3.3 Removing a Mini-App

1. User swipes or taps "Remove" on an installed mini-app.
2. Confirmation: "Remove Recipes? This will delete all recipe data. [Export first] [Cancel] [Remove]".
3. **Remove animation:** the entry shrinks and fades; neighbors reflow.
4. `onUninstall()` runs: deregisters tools, unsubscribes from events, deletes the SQLite file (or archives it), clears cached chat cards.

**Chat cannot be removed.** It is the shell itself.

### 3.4 Reordering

Drag-and-drop in the Mini-App Manager and sidebar. Order persists in UserDefaults. The sidebar is scrollable, so there is no hard cap on mini-app count.

---

## 4. Chat Overlay States

Chat is always present. What changes is how much screen it takes and whether a mini-app is visible behind it. There are three states; every mini-app interaction happens through one of them.

### 4.1 State A — Expanded Chat (default)

The full-screen chat described in [`Chat/DESIGN.md`](./Chat/DESIGN.md). Nothing behind it; the sidebar is available via the hamburger button.

```
┌────────────────────────────────┐
│  ≡    Chat title     (center)  │
├────────────────────────────────┤
│                                │
│  [assistant message]           │
│              [user bubble]     │
│  [thinking / tool / code]      │
│                                │
│  ...                           │
├────────────────────────────────┤
│  [composer pill]               │
└────────────────────────────────┘
```

- Entered on app launch (if the last-open surface was Chat) or by tapping **New Chat** or any existing chat in the sidebar.
- Exited by selecting a mini-app from the sidebar (→ State B) or by pulling the chat down into a bubble (→ State C).

### 4.2 State B — Mini-App with Floating Chat

The selected mini-app fills the screen. A **floating composer** sits pinned to the bottom; above it, a **floating chat panel** shows the last ~N messages of the active chat. The mini-app scrolls freely underneath. This is the "do work alongside the AI" mode.

```
┌────────────────────────────────┐
│  ← Todo                    ⋮  │ ← mini-app nav chrome
├────────────────────────────────┤
│  ▢ Buy groceries               │
│  ▢ Pick up laundry             │
│  ☑ Book dentist                │
│  ▢ Pay rent           ← long-press opens focused view
│  ...                           │
│                                │
│  ╭────────────────────────────╮│
│  │ ← I've added those tasks  ││ ← floating chat panel
│  │   to your list.            ││   (latest N messages, semi-translucent)
│  │                            ││
│  │ [todo-chat-card: 4 tasks] ││ ← rich embedded card
│  ╰────────────────────────────╯│
│  ╭────────────────────────────╮│
│  │ Chat with Super      ▾ 🎤 ││ ← floating composer (same pill)
│  ╰────────────────────────────╯│
└────────────────────────────────┘
```

- **Floating chat panel:** a rounded, elevated card with a translucent blurred backdrop. Height is clamped — by default shows the last ~3 messages; user can drag its top edge to grow it up to 75% of the screen, or flick it all the way up to re-enter State A (Expanded).
- **Floating composer:** the same composer from State A, pinned to the bottom as a pill. Its width matches the floating chat panel.
- **Mini-app content:** fills the screen behind the chat; scrollable independently. The bottom inset of the mini-app view is sized so content isn't permanently obscured by the composer — a small `safe-area-bottom` reserve matches the composer's height.
- Entered by selecting a mini-app from the sidebar, or by deep-linking from a chat message into a specific mini-app record.
- Exited to State A by flicking the chat panel up; exited to State C by flicking the chat panel and composer down together.

### 4.3 State C — Minimized Chat Bubble

The chat collapses to a **44pt circular bubble** in the bottom-right (iPhone) or lower-right corner (iPad/Mac), floating over the mini-app. The mini-app now owns the full screen.

```
┌────────────────────────────────┐
│  ← Todo                    ⋮  │
├────────────────────────────────┤
│                                │
│  ▢ Buy groceries               │
│  ▢ Pick up laundry             │
│  ☑ Book dentist                │
│  ▢ Pay rent                    │
│  ▢ Call mom                    │
│  ▢ Schedule oil change         │
│  ...                           │
│                                │
│                                │
│                          ╭──╮  │
│                          │✦│  │ ← chat bubble (accent fill, 44pt)
│                          ╰──╯  │
└────────────────────────────────┘
```

- **Tap** the bubble → expands back into State B (floating chat + composer).
- **Long-press / drag** the bubble → can be moved to any corner; position sticks across sessions.
- **Unread / streaming indicator:** a subtle pulsing ring around the bubble if the AI is mid-response or a new message arrived while minimized.
- **Silenced while typing:** if the user is typing in a mini-app text field (e.g., editing a todo title), the bubble fades to 40% opacity until the field is dismissed.
- Entered by dismissing the floating chat (flicking down) in State B.
- Exited by tapping the bubble (→ State B) or dismissing via a mini-app's back button back to an empty canvas (→ the bubble persists but may auto-hide if no mini-app is active).

### 4.4 State Transitions

```
   ┌──────────────────┐   select mini-app   ┌──────────────────────┐
   │  A — Expanded     │────────────────────▶│  B — Mini-App +      │
   │  Chat             │◀────────────────────│     Floating Chat    │
   └──────────────────┘   flick panel up     └──────────────────────┘
             ▲                                            ▲   │
             │                                            │   │ flick panel down
             │                                            │   ▼
             │                          tap bubble ┌──────────────────┐
             │                                    │                   │
             │ (from mini-app back) ◀─────────────▶│  C — Bubble +    │
             │                                    │     Mini-App      │
             │                                    └──────────────────┘
```

Transitions are spring animations (damping 0.75, response 0.35); the chat panel's height interpolates with the composer staying visually anchored at the bottom (matched geometry).

### 4.5 Platform Adaptations

- **iPhone:** as described above. Sidebar slides over the chat.
- **iPad:** in landscape the sidebar can be pinned as a persistent left rail (configurable); State B renders the floating chat + composer as a panel on the right half of the screen while the mini-app fills the left half. State C places the bubble in the bottom-right of the active region.
- **macOS:** the sidebar is a persistent left pane. State B renders the chat as a **right-side floating panel** (draggable, resizable). State C places the bubble in the window corner; it persists across window resizes but is bound to the window, not the screen.
- **Reduce Motion** replaces all state-transition springs with crossfades at 200ms.

---

## 5. Bi-Directional AI Interactions

The signature of Super is that **the conversation and the mini-apps know about each other in both directions**. Any action the AI can take, the user can also take by hand — and vice versa, any item the user is looking at can be piped into the chat.

### 5.1 Chat → Mini-App

When the AI calls a tool registered by a mini-app, two things happen:

1. A **rich chat card** renders inline in the chat (rendered by the mini-app's own `ChatCardRenderer`, not by Chat). Example: after `todo.createMany([…])`, ToDo provides a card with a mini-list of the 4 new tasks, each tappable.
2. An `SuperEvent` fires on the bus (`todoCreated`, `recipeSaved`, …). If the mini-app is visible behind the chat (State B), it animates the new record into view in real time.

**Deep-linking from a chat card.** Every chat card includes a primary action that routes into the mini-app at the referenced record. Tapping "View in ToDo" on the todo-batch card transitions A→B (or C→B if minimized), loads the ToDo mini-app behind the chat, and scrolls/selects the referenced task. The router uses `super://<applet>/<recordId>` URIs internally, but users never see them.

**Deep-linking from message text.** When an assistant message references a specific record by name (e.g., "…Revelation 3:20 says…"), Chat can render that reference as a tappable inline token. Tapping it invokes the same deep-link flow. Mini-apps register URL templates for their record types so Chat knows when a reference should become tappable.

### 5.2 Mini-App → Chat

Long-pressing any record inside a mini-app opens a **focused action sheet**. Alongside the mini-app's own actions (edit, delete, set priority, …), the sheet always exposes two shell-provided actions:

- **Add to current chat** — inserts the record as a user message in the active chat. Card-shaped, carries a reference to the record (not a copy of its text). The AI can read it and act on it.
- **Start new chat with this** — opens a fresh chat seeded with the record as the first user message (or system-attached context, depending on the record type). Transitions to State A.

```
┌──────────────────────────────────┐
│  Pay rent                        │
│  due Apr 1 · high priority       │
├──────────────────────────────────┤
│  ✎   Edit                        │
│  ⚑   Change priority             │
│  🗓   Reschedule                 │
├──────────────────────────────────┤
│  ✦   Add to current chat        │ ← shell-provided
│  ✦   Start new chat with this   │ ← shell-provided
├──────────────────────────────────┤
│  🗑   Delete                    │
└──────────────────────────────────┘
```

Examples from the initial mini-app set:

- **Bible:** highlight a range of verses, long-press → "Add to chat" sends the passage (with reference) as an attachment. "Start new chat" opens a fresh thread seeded with it.
- **ToDo:** long-press any task → "Add to chat" references the task; the AI can then ask clarifying questions or propose updates.
- **Recipes:** long-press a recipe → "Add to chat" lets the user ask for substitutions or scaling.
- **Finance:** long-press a transaction → "Add to chat" lets the user ask "tag all like this as commute."

The record-reference payload is small and structured — `{appletId, recordType, recordId, displayTitle, previewText}` — never the full record body. The AI resolves the full body through the mini-app's tool interface when needed.

### 5.3 In-Chat Card Rendering

Each mini-app ships one or more `ChatCardRenderer`s. The shell looks up the right renderer by `{appletId, cardKind}` at display time. Renderers receive a typed payload from the tool call and return SwiftUI — there is no server-driven UI. Common card kinds:

- **Single-record summary** — one task, one recipe, one verse.
- **Batch summary** — N records with a small preview list (the "4 tasks created" case).
- **Preview / confirmation** — shown before a destructive or ambiguous action; user approves/rejects inline.

Cards render at roughly the width of an assistant message in expanded chat, and at the floating chat panel's width in State B. They use the mini-app's **accent color** for their iconography and accent strip, on top of the shell's pastel-green background — so a Bible card reads differently from a Todo card at a glance without shouting.

---

## 6. How New Mini-Apps Plug In

The system must support adding new mini-apps with **zero changes to existing mini-apps or the shell's core code**.

### 6.1 Plugin Contract

A new mini-app only needs to:

1. **Conform to `SuperApplet`** — metadata, lifecycle, event subscriptions.
2. **Define its GRDB schema** — in its own SQLite file, isolated from other mini-apps.
3. **Register its tools** (array of `ToolRegistration`) — Chat auto-discovers them.
4. **Register chat-card renderers** — one per card kind the mini-app wants to render in chat.
5. **Register record-action handlers** — for long-press focused views on its records.
6. **Provide its root SwiftUI view** — the shell embeds this behind the chat overlay.

That's it. No changes to the shell, no changes to other mini-apps.

### 6.2 Auto-Discovery at Build Time

Mini-apps are Swift Packages in the monorepo, registered once at the composition root:

```swift
@main
struct SuperApp: App {
    let registry = AppletRegistry(applets: [
        ToDoApplet(),
        RecipesApplet(),
        BibleApplet(),
        FinanceApplet(),
        // Add new mini-apps here
    ])
    // ...
}
```

User preferences (which mini-apps are active, their order) are stored in UserDefaults; the registry filters the full list by those preferences.

### 6.3 Future: Dynamic Loading

Deferred for v2+. Would enable third-party mini-apps and independent updates. Not needed for v1.

---

## 7. Notification Routing

Each mini-app can emit notifications. The shell's notification router decides where they go.

```
Mini-app emits notification
         │
         ▼
┌──────────────────────┐
│ Notification Router  │
└────────┬─────────────┘
         │
   ┌─────┴──────┐
   ▼            ▼
 System       Notifications
  Push        (in-app inbox — a future mini-app)
```

- **System push** — time-sensitive (a recipe timer, a high-priority todo overdue, a Finance fraud alert).
- **In-app inbox** — accumulates in a future Notifications mini-app. Tapping an entry deep-links into the relevant mini-app record (same router as chat deep-links).

| Source | Urgency | Destination |
|--------|---------|-------------|
| Recipes: timer done | High | System push |
| ToDo: task overdue | Medium | In-app + tab badge |
| Finance: unusual transaction | Critical | System push + in-app + force-open Finance |
| Bible: daily reading reminder | Low | In-app only |

---

## 8. Visual Design

### 8.1 Brand & Palette

Super's identity is a **pastel green system**, applied globally to the chat surface and inherited by mini-apps. The accent color and background tokens are the same across all mini-apps so the whole app reads as one surface, not five (see `Chat/DESIGN.md` §10 for the token list).

| Theme | Background | Accent |
|-------|-----------|--------|
| Light (default) | Soft pastel green | Deeper pastel green |
| Dark | Deep green | Muted mint |
| Sepia | Warm cream | Terracotta |

### 8.2 Mini-App Accents

Each mini-app has a **secondary accent** used only for its own iconography and chat card accent strips — not for global chrome. This keeps cards distinguishable at a glance without fragmenting the overall palette.

| Mini-App | Icon | Secondary Accent |
|----------|------|------------------|
| Chat | ✦ spark (Instrument Serif) | Pastel green (primary) |
| ToDo | ☑ checklist | Cobalt |
| Recipes | 🍳 pan | Warm ochre |
| Bible | ✝ cross | Plum |
| Finance | ▵ triangle | Deep teal |

Secondary accents are muted derivatives (OKLCH-shifted) of the primary palette — not raw bright colors — so they coexist with the pastel green base.

### 8.3 Typography

Inherits directly from Chat (see [`Chat/DESIGN.md`](./Chat/DESIGN.md) §2.2). Mini-apps use the same stack: Instrument Serif (display), Geist (body), JetBrains Mono (code/numbers). Mini-apps MUST NOT introduce additional typefaces.

### 8.4 Density & Information Hiding

"Hide until expanded" is the core rule. Examples:

- Assistant thinking and tool calls render as collapsible blocks, not open panels.
- Long-press focused views are modal — they replace a visible chrome strip, not add to it.
- Mini-apps default to list views with one record per row; detail views are pushed, not always-open.
- The chat's composer footer pills (model / verbosity) open upward only on tap.

Anything that could be a detail view should start as one line until tapped.

### 8.5 Transitions

| Event | Animation | Duration |
|-------|-----------|----------|
| Open mini-app from sidebar (A → B) | Mini-app crossfades in, chat panel springs from bottom | 350ms |
| Minimize chat (B → C) | Panel + composer slide down, bubble scales up from bottom-right | 300ms |
| Tap bubble (C → B) | Bubble scales down, panel + composer spring up | 300ms |
| Expand to full chat (B → A) | Panel expands, composer stays anchored, mini-app crossfades out | 400ms |
| Chat card appears in chat | Fades in with 4pt upward translate | 200ms |
| Chat creates record (card ↔ mini-app visible) | Card highlights, record materializes in the mini-app | 400ms staggered |
| Record long-press → focused view | Scale spring + blur backdrop | 250ms |
| Install mini-app | Sidebar row spring-scales up from 0 | System default spring |

All animations respect Reduce Motion (see §10).

---

## 9. Settings

### 9.1 Shell Settings

Opened from the sidebar's floating gear button (see `Chat/DESIGN.md` §6.4). Panes:

- **Account** (username/password, see `AUTH.md`)
- **Mini-Apps** (install / uninstall / reorder — the Mini-App Manager)
- **Appearance** (theme, font size — shared across all mini-apps; spacing is derived from font size)
- **Models** (LLM endpoints + keys)
- **System Prompt** / **Default Verbosity** (chat defaults)
- **Notifications** (per-mini-app toggles + global push permission)
- **Privacy & Security** (biometric lock, data export)
- **About** / **Data** (export / clear)

### 9.2 Mini-App Settings

Each mini-app manages its own settings screen. Reached either from a gear inside the mini-app, or from a "Mini-App Settings" section in shell Settings that lists each installed mini-app and pushes into its own pane.

---

## 10. Accessibility

- **VoiceOver:** all navigation affordances (hamburger, sidebar rows, chat bubble, long-press actions) are labeled. State transitions announce the new context ("Now in Todo, chat minimized.").
- **Dynamic Type:** typography scales across all three chat states and all mini-apps. Floating chat panel height adjusts to fit larger text.
- **Reduce Motion:** spring state transitions become instant crossfades. The bubble's unread pulse becomes a static dot. Chat-card materialize animations become simple fade-ins.
- **Switch Control / Voice Control:** every interactive element has accessibility identifiers, including the chat bubble and the long-press record actions.
- **Contrast:** at least AA for all ink-on-bg pairs across the three themes; focused-view sheets darken the backdrop behind them for clear separation without relying on blur alone.
