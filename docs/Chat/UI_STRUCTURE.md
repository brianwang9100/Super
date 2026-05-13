# Chat: SwiftUI Structure

> High-level map of the Chat applet's SwiftUI surface — what view owns what, how the screens stack, and which view model drives each one.
>
> **Companion docs:**
> - [`DESIGN.md`](./DESIGN.md) — visual spec (themes, typography, motion, design tokens, pixel-level layout)
> - [`ARCHITECTURE.md`](./ARCHITECTURE.md) — data models, persistence, orchestration loop, LLM streaming
> - [`../NAMING_CONVENTIONS.md`](../NAMING_CONVENTIONS.md) — the taxonomy for naming new SwiftUI views (Part 4). **Read this before coining a new name.**
>
> This doc is intentionally short. If you want pixels, read DESIGN. If you want the ChatSession/LLM loop, read ARCHITECTURE. If you want naming rules, read NAMING_CONVENTIONS. This one is the org chart.

---

## 1. Composition Root

The app target (`App/`) is the composition root. It builds the dependency graph once at launch (`AppBootstrap`) and then renders a single host view (`ContentView` → `ChatHostView`) that stacks three Chat surfaces in a `ZStack`:

```
ChatHostView                                                (App/ContentView.swift)
├── ChatScreen        — base layer, always rendered          (Chat/UI/ChatScreen.swift)
├── SidebarDrawer     — overlay, gated on @State sidebarOpen (Chat/UI/SidebarDrawer.swift)
└── SettingsSheet     — overlay, gated on @State settingsOpen(Chat/UI/Settings/SettingsSheet.swift)
```

`ChatHostView` owns:
- The three `@State` view models — `ChatScreenViewModel`, `SidebarViewModel`, `SettingsViewModel` — each `@Observable @MainActor final class` (no Combine, no ObservableObject).
- The two overlay-visibility bindings (`sidebarOpen`, `settingsOpen`).
- The active `SuperTheme`, re-derived whenever the persisted theme id changes.
- Conversation-switching plumbing: tapping a row in the sidebar rebuilds `ChatScreenViewModel` against the new conversation id; tapping "New Chat" constructs an in-memory draft conversation that doesn't hit GRDB until the user sends a first message (lazy persist via `LazyConversationDriver`).

`ContentView` itself also defines two trivial private screens — `LoadingScreen` and `FailureScreen` — used during bootstrap before `ChatHostView` is ready.

The Sidebar and Settings overlays never coexist visually because opening Settings always fires through `onOpenSettings` *after* the sidebar has started its dismissal animation — see the callback contract on `SidebarDrawer`.

---

## 2. ChatScreen — the base layer

`ChatScreen` is a `VStack(spacing: 0)` of three regions. Header pinned top, composer pinned bottom, transcript fills the middle and switches to an empty-state view when there are no messages.

```
ChatScreen                                       (Chat/UI/ChatScreen.swift)
├── ChatHeader              ⟵ 40pt hamburger · centered title · 40pt spacer
│                              (Chat/UI/ChatHeader.swift)
│
├── content                 ⟵ branches on viewModel.items.isEmpty
│   ├── ChatEmptyState      ⟵ time-of-day greeting + spark
│   │                          (Chat/UI/ChatEmptyState.swift)
│   └── MessageList         ⟵ scrollable transcript
│                              (Chat/UI/MessageList.swift)
│       ├── UserBubble             — right-aligned soft-green bubble
│       ├── AssistantMessage       — markdown text + thinking + tool calls
│       │   ├── ThinkingBlock        ⟵ collapsible, with "Thought for Xs"
│       │   ├── ToolCallBlock        ⟵ collapsible, with INPUT/RESULT panels
│       │   ├── MarkdownText         ⟵ MarkdownUI + Splash code highlighting
│       │   │                            (Chat/UI/Markdown/)
│       │   └── MessageActionButton  ⟵ Copy / Regenerate row
│       ├── CompactionBanner       — "COMPACTED" divider + summary
│       ├── StreamingTail          — in-flight assistant text + caret + spark
│       └── ErrorBanner            — transport/provider error with Retry
│
└── ChatComposer            ⟵ rounded 26pt capsule
                                (Chat/UI/ChatComposer.swift)
    ├── TextField (multi-line, vertical axis, 1–6 lines)
    ├── ChatComposerFooter  ⟵ trailing row inside the capsule
    │   │                      (Chat/UI/ChatComposerFooter.swift)
    │   ├── ModelPill          — current model dropdown   (Chat/UI/ModelPill.swift)
    │   └── ContextMeter       — token usage progress     (Chat/UI/ContextMeter.swift)
    └── trailingButton      ⟵ 34pt circle, four mutually-exclusive states:
                                · mic           (empty composer, mic available)
                                · mic.slash     (empty composer, mic unavailable)
                                · arrow.up      (composer has text)
                                · stop.fill     (streaming or recording — cancels)
```

The message-row views (`UserBubble`, `AssistantMessage`, `ThinkingBlock`, `ToolCallBlock`, `CompactionBanner`, `StreamingTail`, `ErrorBanner`, `WaitingSpark`, `TypingCaret`, `MessageActionButton`) each live in their own file under `Chat/UI/Messages/`.

**View model:** `ChatScreenViewModel` (`Chat/ViewModels/ChatScreenViewModel.swift`).

Owns: composer buffer, projected `MessageList.Item` list, live `streamingTail`, terminal `error`, model selection, the active verbosity used for rendering (seeded at init from `ChatSettings.defaultVerbosity` and pushed in by the host when the Settings sheet changes it), used/max token counts, header title (mutated by `TitleGenerator` after the first exchange), and a `VoiceInputController` collaborator.

Driven by: an injected `ChatSessionDriver` (in production a `LiveChatSessionDriver` wrapping the per-conversation `ChatSession` actor from `ChatSessionStore`). The view model consumes the actor's `AsyncStream<ChatEvent>` and folds each event into observable state — that's the bridge between the orchestration loop in ARCHITECTURE §5 and what SwiftUI re-renders.

---

## 3. SidebarDrawer — left overlay

A 300pt-wide left-anchored drawer that overlays `ChatScreen`. Tap-to-dismiss scrim at 30% black; the drawer paints its own scrim so the host doesn't have to coordinate dimming. Slides in from the leading edge over 220ms.

```
SidebarDrawer                                    (Chat/UI/SidebarDrawer.swift)
├── scrim (Color.black @ 0.30)         ⟵ tap closes
└── drawerSurface (VStack)
    ├── wordmarkHeader                 ⟵ "Super" italic serif 36pt
    │                                     "v{x} · personal" mono caption
    │
    ├── ScrollView { LazyVStack }
    │   ├── newChatButton              ⟵ accent-filled CTA, 14pt radius
    │   ├── appletRow(.todo)           ⟵ visual placeholders for MVP;
    │   ├── appletRow(.recipes)            tapping is a no-op until the
    │   ├── appletRow(.bible)              real applet registry lands
    │   ├── appletRow(.finance)            (see AppletDestination doc)
    │   │
    │   ├── sectionLabel("Chats")      ⟵ 11pt uppercase, letter-spaced
    │   └── ForEach(chats) { ChatRow }
    │       ├── SpinnerRing            ⟵ leading, only when chat.running
    │       └── title                  ⟵ accent ink + accentSoft fill
    │                                     when isActive
    │
    └── footer (overlay alignment: .bottom)
        ├── identityCapsule            ⟵ initials circle + display name
        └── Settings gear button       ⟵ 44pt accent-filled circle
```

**View model:** `SidebarViewModel` (`Chat/ViewModels/SidebarViewModel.swift`).

Owns: projected `chats: [ChatItem]` (newest-first), `activeConversationId`, and an optional in-memory `draftConversation` (the "New Chat" row that hasn't been persisted yet).

Sources: pulls from `ConversationRepository` for the list and `ChatSessionStore.runningConversations()` for the per-row spinner. Currently refresh-on-demand (the host calls `refresh()` when the drawer opens or after the lazy-persist promotes a draft); live `ValueObservation`-backed reactivity is deferred to a future milestone.

**Callback contract:** every action callback (`onSelectConversation`, `onNewChat`, `onOpenSettings`, `onSelectApplet`) fires *after* the drawer flips its `isPresented` binding to `false`. The host can rely on the drawer being in a closing state when its callback fires — this is why `ChatHostView` can present the Settings sheet on the next tick without a visible overlap.

---

## 4. SettingsSheet — bottom-sheet overlay

A modal bottom sheet anchored 40pt from the top with a 22pt top-corner radius. 25% black scrim. Slide curve `cubic-bezier(0.32, 0.72, 0, 1)` over 300ms; swapped for an opacity fade when Reduce Motion is on.

Sub-pane navigation is a `NavigationStack` driven by `viewModel.navigationPath: [Pane]`. The sheet resets the path to empty on dismiss so re-presenting always lands on `.root`; external callers (e.g. the composer's "Manage models…" link) deep-link by mutating the path *before* flipping `isPresented`.

```
SettingsSheet                              (Chat/UI/Settings/SettingsSheet.swift)
├── scrim (Color.black @ 0.25)
└── sheetSurface (VStack)
    ├── SettingsHeader                ⟵ close (X) or back chevron · title
    │                                    (Chat/UI/Settings/Components/SettingsHeader.swift)
    │
    └── NavigationStack(path:)
        └── one of:
            ├── SettingsRootPane          ⟵ Pane.root
            ├── SettingsModelsPane        ⟵ Pane.models
            ├── SettingsModelDetailPane   ⟵ Pane.modelDetail(id:)
            ├── SettingsThemePane         ⟵ Pane.theme
            ├── SettingsPromptPane        ⟵ Pane.prompt
            ├── SettingsVerbosityPane     ⟵ Pane.verbosity
            ├── SettingsAppearancePane    ⟵ Pane.appearance
            ├── SettingsToolsPane         ⟵ Pane.tools
            ├── SettingsCompactionPane    ⟵ Pane.compaction
            ├── SettingsDataPane          ⟵ Pane.data
            └── SettingsAboutPane         ⟵ Pane.about
```

Files all live under `Chat/UI/Settings/Panes/`. Shared building blocks live under `Chat/UI/Settings/Components/`:

- `SettingsGroup` — rounded-14pt card with a faint border and `--bg-raised` fill
- `SettingsRow` — leading icon · label · trailing value/chevron, hairline divider between rows
- `SettingsToggle` — iOS-style 44×26 switch
- `SettingsHeader` — sheet/sub-pane chrome

Row-leading icons (`ModelsIcon`, `ThemeIcon`, `PromptIcon`, `VerbosityIcon`, `AppearanceIcon`, `ToolsIcon`, `CompactionIcon`, `DataIcon`, `AboutIcon`) and chrome icons (`CloseIcon`, `BackChevronIcon`, `ForwardChevronIcon`, `PlusIcon`, `CheckIcon`) live in `Chat/UI/Icons/SettingsPaneIcons.swift`. Sidebar applet icons (`TodoIcon`, `RecipeIcon`, `BibleIcon`, `FinanceIcon`, `NewChatIcon`, `SettingsIcon`) live in `Chat/UI/Icons/SidebarIcons.swift`.

### Root pane layout

```
SettingsRootPane                        (.../Panes/SettingsRootPane.swift)
├── accountChip                         ⟵ email pill
│
├── SettingsGroup                       ⟵ "Configured" group
│   ├── Models       → .models          "N configured"
│   └── Theme        → .theme           current theme name
│
├── SettingsGroup                       ⟵ "Behavior" group
│   ├── System Prompt    → .prompt
│   ├── Default Verbosity→ .verbosity   current verbosity
│   ├── Appearance       → .appearance
│   ├── Tools            → .tools       "N enabled"
│   └── Compaction       → .compaction  "Auto" / "Manual"
│
└── SettingsGroup                       ⟵ "About" group
    ├── Data         → .data            "N chats"
    └── About        → .about           "v{x}"
```

**View model:** `SettingsViewModel` (`Chat/ViewModels/SettingsViewModel.swift`).

Owns: the persisted `ChatSettings` snapshot, the configured-models list (`ModelRow`), the registered-tools list (`ToolRow`), the conversation count, account chrome (email + app version), and the navigation path. Every mutation writes through to the underlying repository (`SettingRepository`, `ModelConfigurationRepository`, `GRDBToolEnablementRepository`) on the same call, so the sheet is always in sync with what's on disk.

---

## 5. View Model Boundaries at a Glance

| Surface | View model | Reads from | Writes to |
|---------|-----------|------------|-----------|
| `ChatScreen` | `ChatScreenViewModel` | `ChatSession` events (via `ChatSessionDriver`), `MessageRepository`, `ToolCallRepository`, `CompactionCheckpointRepository` | composer text · projected items · streaming tail (in-memory only — see ADR-BB-003 in ARCHITECTURE.md) |
| `SidebarDrawer` | `SidebarViewModel` | `ConversationRepository`, `ChatSessionStore.runningConversations()` | (none — navigation only) |
| `SettingsSheet` | `SettingsViewModel` | `SettingRepository`, `ModelConfigurationRepository`, `GRDBToolEnablementRepository`, `ToolRegistry`, `LLMProviderRegistry`, `ConversationRepository` (for chat count) | the same repositories on every edit |

All three view models are `@Observable @MainActor final class`, mutate only on the main actor, and are constructed by `ChatHostView` from the bootstrap `AppDependencies`.

---

## 6. Theming Hook

Every public Chat view reads its colors from a single `SuperTheme` value injected via the `\.superTheme` environment key (`Chat/UI/Theme/SuperTheme.swift`). `ChatHostView` derives the theme from `SettingsViewModel.settings.themeId` and pushes it down with `.superTheme(theme)` on each overlay's root.

This means snapshot tests can render any view against any theme by wrapping it in `.superTheme(.make(.light))` / `.dark` / `.sepia` without touching settings persistence — which is exactly what the snapshot suite under `Tests/ChatTests/UI/__Snapshots__/` does.

---

## 7. Naming new views

See [`../NAMING_CONVENTIONS.md` Part 4](../NAMING_CONVENTIONS.md#part-4--swiftui-view-layer-chat-applet) for the full taxonomy (Screen / Drawer / Sheet / Pane / Region / Pill / Meter / Row / Bubble / Block / Banner / Group / Toggle / Button / Icon / Primitive / Style / Modifier) and the four rules that govern when to add a `View` suffix, when to one-struct-per-file, and how to name state vs. view types.

---

*Last updated: 2026-05-11*
