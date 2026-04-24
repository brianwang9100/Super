# Super: Top-Level Design

> How the Super shell manages, displays, and orchestrates its applet-based applications.

---

## 1. Purpose of This Document

This document covers the **app shell** — the container that hosts all Super applets. Individual applets (Chat, ToDo, etc.) will each have their own `design.md` covering applet-specific UI/UX. This document focuses on:

- How applets are displayed and navigated
- How applets are added, removed, and reordered
- How the shell adapts across iPhone, iPad, and macOS
- How future applets plug into the system without architectural changes

---

## 2. The Shell Concept

Super is not a single app — it's a **shell** that hosts a dynamic set of applets. Think of it like a personal operating system: the shell provides navigation, identity, shared services, and a communication layer. Applets plug into the shell and gain access to all of that for free.

The shell owns:
- **Navigation chrome** (tab bar, sidebar, toolbar)
- **Applet Registry** (which applets are installed and active)
- **Event bus** (cross-applet communication)
- **Animation engine** (cross-applet visual coordination)
- **Notification routing** (directing notifications to the right applet or to Notifications)
- **Shared design system** (typography, colors, spacing, common components)

The shell does NOT own:
- Any applet's internal UI, data, or business logic
- Applet-specific settings (each applet manages its own)

---

## 3. Applet Registry & Lifecycle

### 3.1 Applet Manifest

Every applet declares itself through a standard protocol:

```swift
protocol SuperApplet {
    /// Unique identifier for this applet
    static var appletId: String { get }

    /// Display metadata
    var displayName: String { get }
    var icon: Image { get }
    var accentColor: Color { get }

    /// The root view for this applet
    @ViewBuilder var rootView: some View { get }

    /// Tools this applet exposes to Chat (AI chatbot)
    var registeredTools: [LLMTool] { get }

    /// Event types this applet publishes and subscribes to
    var publishedEvents: [SuperEvent.Type] { get }
    var subscribedEvents: [SuperEvent.Type] { get }

    /// Applet lifecycle
    func onActivate()    // called when applet becomes visible
    func onDeactivate()  // called when applet goes to background
    func onInstall()     // called when first added to shell
    func onUninstall()   // called when removed — must clean up data
}
```

### 3.2 Adding an Applet

**User flow:**
1. User opens the **Applet Manager** (accessible from shell settings or a "+" button in the navigation)
2. Applet Manager shows available applets in two sections:
   - **Installed** — currently active applets with toggle switches and reorder handles
   - **Available** — applets that can be added (shipped with the app but not yet activated)
3. User taps "Add" on an applet
4. **Installation animation:** the applet icon drops into the navigation bar/sidebar with a spring animation. On iPhone, the tab bar reorganizes with the new tab sliding in. On Mac/iPad sidebar, the new item fades in and the list reflows.
5. The applet's `onInstall()` is called — it sets up its SwiftData container, registers tools with Chat, and subscribes to relevant events
6. The applet is immediately navigable

**Architectural requirement:** Adding an applet must NOT require an app restart. The shell's navigation is driven by the Applet Registry, which is an `@Observable` object. When the registry changes, SwiftUI automatically re-renders navigation.

### 3.3 Removing an Applet

**User flow:**
1. User opens Applet Manager
2. User swipes to remove or taps "Remove" on an installed applet
3. **Confirmation dialog** warns that applet data will be deleted (with option to export first, if applicable)
4. **Removal animation:** the applet's tab/sidebar item shrinks and fades out; remaining items reflow smoothly
5. The applet's `onUninstall()` is called — it:
   - Deregisters its tools from Chat
   - Unsubscribes from all events
   - Deletes its SwiftData container (or archives it, based on user choice)
   - Clears any cached data
6. The navigation updates immediately

**Protected applets:** Chat (the AI chatbot) cannot be removed — it's the orchestration hub. All other applets are optional.

### 3.4 Reordering Applets

Users can drag-and-drop to reorder applets in the Applet Manager. This changes the tab order (iPhone) or sidebar order (iPad/Mac). The reorder persists via UserDefaults.

On iPhone, if more than 5 applets are active, the standard iOS "More" tab pattern applies, or we implement a scrollable tab bar.

---

## 4. Navigation & Layout

### 4.1 iPhone Layout

```
┌─────────────────────────┐
│       [Applet View]     │
│                         │
│                         │
│                         │
│                         │
│                         │
│                         │
├─────────────────────────┤
│ 🧠  📋  📅  🏠  ⚡     │
│ Chat Todo Cal Home More │
└─────────────────────────┘
```

- **Tab bar** at the bottom with applet icons
- Each tab hosts one applet's root view
- Active tab indicated with filled icon + accent color
- Tab bar supports badge counts (e.g., unread notifications, overdue todos)
- If >5 applets installed, overflow goes to a "More" tab or the tab bar becomes horizontally scrollable

**Notification overlay:** When a cross-applet action occurs (e.g., AI creates a todo while user is in the chat), a floating toast/banner appears at the top showing what happened, with a tap target to navigate to the affected applet.

### 4.2 iPad Layout

```
┌────────┬────────────────────────────────────┐
│ 🧠 Chat│                                    │
│ 📋 Todo│         [Primary Applet View]      │
│ 📅 Cal │                                    │
│ 🏠 Home│                                    │
│        │                                    │
│        ├────────────────────────────────────│
│        │     [Secondary Applet View]        │
│ ──── ──│     (optional split, resizable)    │
│ ⚙ Set  │                                    │
└────────┴────────────────────────────────────┘
```

- **Sidebar** on the left with applet icons + labels
- **Primary content area** shows the selected applet
- **Optional split view:** user can pin a second applet (typically Chat) alongside the primary applet. This enables the signature interaction: chat on one side, see the todo list update in real-time on the other.
- Sidebar collapses to icons-only in compact width

### 4.3 macOS Layout

```
┌──────────────────────────────────────────────────────┐
│ ◀ ▶   Super                          🔔  ⚙  👤  │
├────────┬─────────────────────┬───────────────────────┤
│        │                     │                       │
│ 🧠 Chat│                     │                       │
│ 📋 Todo│   [Primary Applet]  │  [Secondary Applet]   │
│ 📅 Cal │                     │   (optional panel)    │
│ 🏠 Home│                     │                       │
│        │                     │                       │
│        │                     │                       │
│ ────── │                     │                       │
│ ⚙ Set  │                     │                       │
└────────┴─────────────────────┴───────────────────────┘
```

- **Persistent sidebar** with applet list (collapsible)
- **Primary + secondary panel** layout (like Mail.app or Xcode)
- Secondary panel is optional — user drags an applet into it or the system opens it automatically during cross-applet actions
- Window supports multiple instances (multiple windows, each with different applet combinations)
- Menu bar integration for quick actions

### 4.4 Cross-Applet Split View Behavior

The split view is critical for the "AI controls everything" experience. Key behaviors:

- **Auto-open:** When Chat performs an action on another applet (creates a todo, adds a calendar event), the shell can auto-open that applet in the secondary panel so the user sees the animation in real time. This is opt-in via a "Show actions live" setting.
- **Manual pin:** User can manually drag an applet to the secondary panel from the sidebar
- **Resize:** The divider between panels is draggable
- **Close:** Secondary panel can be dismissed, returning to single-applet view
- **Memory:** The shell remembers the user's preferred split layout per applet combination

---

## 5. Applet Manager UI

### 5.1 Applet Manager Screen

The Applet Manager is the control center for customizing the Super experience.

```
┌─────────────────────────────────┐
│  Applet Manager                 │
│                                 │
│  INSTALLED                      │
│  ┌─────────────────────────┐    │
│  │ ≡ 🧠 Chat (Chat)   🔒│   │  ← locked, cannot remove
│  │ ≡ 📋 ToDo (Todos)      ⊝│   │  ← drag handle + remove
│  │ ≡ 📅 Calendar (Calendar)  ⊝│   │
│  │ ≡ 🏠 Home (Home)     ⊝│   │
│  └─────────────────────────┘    │
│                                 │
│  AVAILABLE                      │
│  ┌─────────────────────────┐    │
│  │ 🔔 Notifications (Notifs)   ⊕│    │
│  │ 💪 Fitness (Fitness)    ⊕│    │
│  │ 📝 Notes (Notes)     ⊕│    │
│  └─────────────────────────┘    │
│                                 │
│  Drag to reorder installed      │
│  applets.                       │
└─────────────────────────────────┘
```

### 5.2 Applet Card (Detail View)

Tapping an applet (installed or available) shows a detail card:
- Applet name, icon, description
- Screenshot / preview of the applet's UI
- Storage usage (for installed applets)
- "Tools" section listing what AI capabilities this applet provides
- Install / Uninstall button

---

## 6. How New Applets Plug In

This is the most architecturally important section. The system must support adding new applets with **zero changes to existing applets or the shell's core code**.

### 6.1 Plugin Contract

A new applet only needs to:

1. **Conform to `SuperApplet` protocol** — provides all metadata and lifecycle hooks
2. **Define its SwiftData schema** — in its own `ModelContainer`, isolated from other applets
3. **Define its AI tools** (optional) — array of `LLMTool` objects that Chat auto-discovers
4. **Define its events** (optional) — event types it publishes/subscribes to on the event bus
5. **Provide its root SwiftUI view** — the shell embeds this in the navigation

That's it. No changes to the shell, no changes to other applets.

### 6.2 Auto-Discovery at Build Time

Since all applets are Swift Packages in the monorepo, applet registration happens at compile time:

```swift
// In the Shell's app setup
@main
struct SuperApp: App {
    let appletRegistry = AppletRegistry(applets: [
        ChatApplet(),    // Always present
        ToDoApplet(),
        CalendarApplet(),
        HomeApplet(),
        NotificationsApplet(),    // Add new applets here
    ])
    // ...
}
```

The user's preferences (which applets are active, their order) are stored in UserDefaults. The registry filters the full applet list by user preferences to determine what's shown.

### 6.3 Future: Dynamic Applet Loading

For v2+, consider dynamic applet loading via Swift Package plugins or frameworks loaded at runtime. This would enable:
- Third-party applets
- Applet updates independent of app updates
- A/B testing new applets with subsets of users

This is a significant architectural investment and not needed for v1.

---

## 7. Notification Routing

### 7.1 How Notifications Flow

Each applet can generate notifications. The shell's notification router determines where they go:

```
Applet generates notification
        │
        ▼
┌─────────────────────┐
│  Notification Router │
│  (Shell service)     │
└────────┬────────────┘
         │
    ┌────┴────┐
    ▼         ▼
 System    Notifications
  Push     (in-app)
```

- **System notifications:** Standard iOS/macOS push notifications for time-sensitive items (calendar reminders, urgent todos, security alerts from home devices). Handled via UNUserNotificationCenter.
- **In-app notifications (Notifications):** Non-urgent items that accumulate in the notification applet. Notifications acts as an inbox of things that need attention across all applets.

### 7.2 Notification Priority Matrix

| Source | Urgency | Destination |
|--------|---------|-------------|
| Calendar: event starting in 15min | High | System push + Notifications |
| ToDo: task overdue | Medium | Notifications (badge on tab) |
| Home: security alert (door unlocked) | Critical | System push + Notifications + force-open Home |
| Home: temperature reached target | Low | Notifications only |

---

## 8. Visual Design Principles

### 8.1 Applet Identity

Each applet has a distinct accent color and icon, but all share the same design system:
- **Typography:** SF Pro (system font) with consistent type scale
- **Spacing:** 4pt grid system
- **Colors:** Each applet gets one accent color; all other chrome is neutral (system background, labels, separators)
- **Icons:** SF Symbols for consistency with the Apple ecosystem
- **Dark mode:** Full dark mode support; applets inherit the shell's appearance setting

### 8.2 Applet Color Palette

| Applet | Accent Color | Icon |
|--------|-------------|------|
| Chat | Purple | brain |
| ToDo | Blue | checklist |
| Calendar | Orange | calendar |
| Home | Green | house.fill |
| Notifications | Red | bell.fill |
| Money | Gold | dollarsign.circle.fill |

### 8.3 Transitions Between Applets

- **Tab switch (iPhone):** Standard iOS tab transition (instant swap, no animation between content)
- **Sidebar selection (iPad/Mac):** Content area crossfades to new applet (150ms, ease-in-out)
- **Split view open/close:** Secondary panel slides in from the right with spring animation
- **Applet install:** New tab/sidebar item scales up from 0 with overshoot spring
- **Applet uninstall:** Tab/sidebar item shrinks to 0 and fades out; siblings reflow

### 8.4 Empty States & Onboarding

When an applet is first installed, it shows a welcoming empty state:
- Applet icon (large, muted)
- Brief description of what the applet does
- Primary CTA to get started (e.g., "Create your first task", "Connect your home")
- Secondary CTA: "Or ask Chat to set it up for you" — encourages the AI-first workflow

**API key onboarding:** If an applet requires a third-party API key (e.g., Chat needs a Claude key, Money needs a Plaid key), the first-run experience is a setup screen that prompts for the key before the applet becomes functional. The setup screen should:
- Explain what the key is for and link to where to get one
- Provide a secure text field for entry (Keychain-backed)
- Validate the key (test API call) before proceeding
- Allow re-entry later via applet settings

---

## 9. Settings Architecture

### 9.1 Shell Settings
- Account management (username/password, see [AUTH.md](./AUTH.md))
- Applet Manager (add, remove, reorder)
- Appearance (light/dark/auto, accent color override)
- Notification preferences (global toggles)
- Privacy & security (biometric lock, data export)

### 9.2 Applet Settings
Each applet manages its own settings screen, accessed via:
- A gear icon within the applet's view, or
- An "Applet Settings" section within Shell Settings that lists per-applet settings

This keeps the shell settings focused and lets applets evolve their settings independently.

---

## 10. Accessibility

- **VoiceOver:** All navigation elements (tabs, sidebar items, Applet Manager) are fully labeled. Applet transitions announce the new applet name.
- **Dynamic Type:** The shell respects system text size. Applet icons in sidebar/tabs scale appropriately.
- **Reduce Motion:** When enabled, cross-applet animations are replaced with simple fades. Applet install/uninstall animations are instant.
- **Switch Control / Voice Control:** All interactive elements have accessibility identifiers for switch and voice control targeting.
