# Super: Top-Level Design

> How the Super shell hosts Chat and its mini-apps, and how the three chat overlay states (expanded / semi-expanded / minimized) coordinate with the mini-app underneath.

> **Status (2026-05-13):** The Chat surface itself is built and the MVP is shipped (M0–M12 all complete, with M11 voice input verified on hardware 2026-05-10). The three-state overlay system, mini-app hosting, and `AppletRegistry` described below are landing in the post-MVP "Shell" track tracked in [`TODO.md`](../TODO.md) § Shell. The fetched 2026-05-13 design (`/tmp/super-design/super/project/ds/chat.html`) supersedes earlier sketches: states are named **minimized / semi-expanded / expanded** and the minimized state is a **full-width "Chat with Super" pill** at the bottom of the viewport (the 44pt circular bubble in older drafts was abandoned).

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

### 2.1 One shell, two app targets

The same shell, mini-app registry, and `MiniApplet` protocol serve **both app targets** in this monorepo — SuperOS and SuperBible (see [`PRODUCT_VISION.md`](./PRODUCT_VISION.md) §13). The only thing that differs per target is the **composition root**, which decides which applets are registered at launch.

**Planned shape (effective at SB-M0; see [`TODO.md`](../TODO.md) § SuperBible):**

- `App/SuperOSApp.swift` → `SuperOSAppBootstrap` → Chat + Bible + Todo (and more, over time).
- `App-SuperBible/SuperBibleApp.swift` → `SuperBibleAppBootstrap` → Chat + Bible + Plans (and more, post-v1).

**Current state (today, pre-SB-M0):** only the SuperOS target exists, and the composition root is still `App/SuperApp.swift` + `App/AppBootstrap.swift` — they get renamed as part of SB-M0 (the same commit that adds the SuperBible target). Do not create a second `@main` file before that rename lands; Xcode rejects duplicate `@main` annotations at compile time, and a stray duplicate is a far harder mistake to back out of than the rename itself.

Every overlay state, every animation choreography, every long-press / deep-link / event-bus interaction described below applies identically to both apps. The shell knows nothing about which target it's running inside — it only knows which applets the bootstrap handed it.

---

## 3. Mini-App Registry & Lifecycle

### 3.1 Mini-App Manifest

Every mini-app declares itself through a standard protocol:

```swift
protocol MiniApplet {
    /// Unique identifier for this mini-app
    static var appletID: String { get }

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

The shipped Swift type (introduced 2026-05-13) is `MiniApplet` — the older `SuperApplet` draft was dropped because the `Super` prefix duplicated the product name without adding meaning. The initial in-tree version exposes only the *display-metadata* slice (`appletID`, `displayName`, `icon`, `accentColor`, `rootView`); the tools / cards / record-actions / event-bus / lifecycle members will land as those subsystems are built.

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

**Chat cannot be removed.** It is the shell's host applet.

### 3.4 Reordering

Drag-and-drop in the Mini-App Manager and sidebar. Order persists in UserDefaults. The sidebar is scrollable, so there is no hard cap on mini-app count.

---

## 4. Chat Overlay States

Chat is always present. What changes is how much screen it takes and whether a mini-app is visible behind it. There are three **settled anchors**; every mini-app interaction settles into one of them. Their canonical Swift identifier is `ChatPresentationState { case minimized, semiExpanded, expanded }`.

The chat surface is **one morphing view** — a single `ChatScreen` whose frame height tracks the user's finger continuously during a drag and snaps to the nearest anchor on release. There is no swap between separate pill / panel / screen view hierarchies; the same `ChatComposer` resizes to *become* the pill in minimized mode, the panel surround fades in and out, the transcript fades alongside the morph, and the corner radius interpolates from 24pt (pill) → 0pt (expanded). Every visual is driven by a `progress: Double` (0 = pill, 1 = expanded) derived from the chat-surface height.

A **drag handle** (36 × 4.5pt pill, `ink-mute @ 55%` resting → `ink-faint @ 70%` while dragging) sits at the top of the chat surface in expanded and semi-expanded states. In minimized mode the handle is hidden and the entire pill body becomes the drag-or-tap target. Dragging anywhere on the chat surface updates the height continuously; on release the surface snaps to the anchor whose height is nearest the release position (with the SwiftUI predicted-end translation factored in as a velocity bias). A hard flick above 1,200pt of predicted-end travel jumps straight to the endpoint anchor in the flick's direction. Snap spring: `cubic-bezier(0.34, 1.4, 0.5, 1)` over 380ms. Reduce Motion replaces the spring with a 200ms crossfade; the drag itself stays finger-tracked (no animation during drag).

A **fixed hamburger button** (36 × 36pt raised pill, top-left inset 12pt, blur backdrop) lives in the shell chrome — it does **not** animate with the chat. It is the entry point to the sidebar applet switcher across all three states.

### 4.1 Expanded

The full-screen chat described in [`Chat/DESIGN.md`](./Chat/DESIGN.md). Nothing behind it; the sidebar is available via the shell-chrome hamburger.

```
┌────────────────────────────────┐
│  ≡                             │ ← shell chrome: hamburger top-left
│              ▬▬                │ ← drag handle (36 × 4.5pt)
│            Chat title          │
├────────────────────────────────┤
│  [assistant message]           │
│              [user bubble]     │
│  [thinking / tool / code]      │
│                                │
│  ...                           │
├────────────────────────────────┤
│  [composer pill]               │
└────────────────────────────────┘
```

- Entered on app launch (if the last-open surface was Chat) or by tapping **New Chat** or any existing chat in the sidebar, or by tapping the **Chat** applet entry.
- Exited by selecting a mini-app from the sidebar (→ minimized, with mini-app behind), or by dragging the chat surface down (→ semi-expanded → minimized).

### 4.2 Semi-Expanded

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

- **Floating chat panel:** a rounded, elevated card with a translucent blurred backdrop (`color-mix(in oklab, var(--bg-raised) 95%, transparent)`, blur 20 + saturate 1.4, radius 22, shadow `0 12px 30px rgba(40,60,50,0.18), 0 30px 80px rgba(40,60,50,0.12)`). Anchored to the bottom with left/right/bottom inset 10pt. Drag handle on top. By default shows the last ~3 messages; the drag-snap is `expanded ↔ semi-expanded ↔ minimized`.
- **Floating composer:** the same composer from Expanded, pinned inside the panel as an inner pill (radius 18, slightly inset). Its width matches the panel.
- **Mini-app content:** fills the screen behind the chat at **0.65 opacity**; scrollable independently. The bottom inset of the mini-app view is sized so content isn't permanently obscured by the panel — a small `safe-area-bottom` reserve matches the panel's height.
- Entered by selecting a mini-app from the sidebar (→ chat snaps from expanded to minimized to give the mini-app its full canvas, then user can tap the pill to climb to semi), or by tapping the minimized pill.
- Exited to expanded by dragging the chat handle up; exited to minimized by dragging the chat panel down.

### 4.3 Minimized

The chat collapses to a **full-width pill** anchored at the bottom of the viewport. The mini-app now owns the full screen behind it (no opacity dim).

```
┌────────────────────────────────┐
│  ≡                             │ ← shell chrome: hamburger persists
├────────────────────────────────┤
│  ▢ Buy groceries               │
│  ▢ Pick up laundry             │
│  ☑ Book dentist                │
│  ▢ Pay rent                    │
│  ▢ Call mom                    │
│  ▢ Schedule oil change         │
│  ...                           │
├────────────────────────────────┤
│ ╭──────────────────────────╮   │
│ │ Chat with Super       🎤 │   │ ← full-width pill, radius 24
│ ╰──────────────────────────╯   │
└────────────────────────────────┘
```

- **Tap** the pill → snaps to semi-expanded.
- **Drag** anywhere on the pill body → live resize, snaps to the nearest anchor on release.
- **Geometry:** left/right inset 12pt, bottom inset 14pt + safe-area-bottom. Radius 26 (matches the composer capsule the pill morphs into — close enough to the prior 24pt). Raised surface (`var(--bg-raised)`) with `1px var(--border-faint)`. Two-layer drop shadow (`0 12px 12px rgba(0,0,0,0.15)` + `0 24px 30px rgba(0,0,0,0.10)`).
- **Affordance:** centered "Chat with Super" placeholder text on the left (rendered by the same `ChatComposer` that becomes the expanded composer at higher progress — at `progress = 0` the text-field is hidden and the label takes its slot), mic glyph (`ink-soft`) on the right.
- **Streaming indicator:** a subtle pulsing accent dot on the right edge replaces the mic when the AI is mid-response.
- Entered by dismissing the semi-expanded panel (drag down) or by selecting a mini-app from the sidebar while Chat was expanded.
- Exited by tapping the pill (→ semi-expanded) or by selecting Chat from the sidebar (→ expanded).

### 4.4 State Transitions

```
   ┌──────────────────┐   tap mini-app from sidebar    ┌──────────────────┐
   │     Expanded      │───────────────────────────────▶│    Minimized      │
   │                   │◀───────────────────────────────│  (pill anchored   │
   └──────────────────┘     tap Chat from sidebar        │   over mini-app)  │
        ▲     │                                          └──────────────────┘
        │     │                                                   ▲   │
   drag │     │ drag down                              tap pill   │   │ drag down
   up   │     ▼                                                   │   ▼
        │  ┌──────────────────┐                                   │
        └──│  Semi-Expanded    │───────────────────────────────────┘
           │  (floating panel) │       drag panel down
           └──────────────────┘
```

Transitions are spring animations (`Animation.timingCurve(0.34, 1.4, 0.5, 1, duration: 0.38)`) applied to the chat-surface's height on snap; during a live drag the height tracks the finger directly with no animation. The composer stays visually anchored at the bottom of the surface at every progress — it never moves; only its content morphs (pill label ↔ multi-line editor, footer row collapses to zero height). Reduce Motion replaces snap springs with `.easeInOut(duration: 0.2)` crossfades; live drag is unaffected.

### 4.5 Platform Adaptations

- **iPhone:** as described above. Sidebar slides over the chat.
- **iPad:** in landscape the sidebar can be pinned as a persistent left rail (configurable); semi-expanded renders the floating chat + composer as a panel on the right half of the screen while the mini-app fills the left half. Minimized places the pill at the bottom of the active region.
- **macOS:** the sidebar is a persistent left pane. Semi-expanded renders the chat as a **right-side floating panel** (draggable, resizable). Minimized places the pill at the bottom of the window; it persists across window resizes but is bound to the window, not the screen.
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

1. **Conform to `MiniApplet`** — metadata (`appletID`, `displayName`, `icon`, `accentColor`, `rootView`). Tools / chat-card renderers / record-action handlers / lifecycle hooks are added once those subsystems exist.
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
        ChatApplet(),
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
| Open mini-app from sidebar (expanded → minimized) | Chat surface springs down into pill; mini-app crossfades in behind | 380ms |
| Tap minimized pill (minimized → semi-expanded) | Pill height interpolates into panel; backdrop dims to 0.65 | 380ms |
| Drag down (semi-expanded → minimized) | Panel collapses into pill, backdrop returns to 1.0 opacity | 380ms |
| Drag up to full chat (semi-expanded → expanded) | Panel height interpolates to full, composer stays anchored | 380ms |
| Tap Chat from sidebar (minimized → expanded) | Pill expands to full chat; backdrop fades away | 380ms |
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
