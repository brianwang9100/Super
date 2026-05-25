# App/Shell — Agent Guidelines

The shell that hosts every applet and overlays Chat on top in three presentation states. **Shared between the SuperOS and SuperBible App Store targets** — individual `*.swift` files here are included in both targets via explicit `sources:` entries in `project.yml`. They are not packaged as a Swift Package; the App targets bundle them directly.

## What lives here

- **`App/Shell/AppShell.swift`** — defines `AppShell`, the chat-overlay-on-applet-backdrop shell rendered by both `SuperOSContentView` (SuperOS) and `SuperBibleContentView` (SuperBible). Owns the `AppletRegistry` (handed in by the target's bootstrap), the `ChatPresentationState`, the sidebar / settings visibility bindings, and the per-conversation view-model rebuild path. Hoists `static let activeAppletStorageKey = "shell.activeAppletID"` so both target bootstraps reference it via `AppShell.activeAppletStorageKey` — the write at `onSelectApplet` time and the read at `bootstrap()` time always agree.
- **`App/Shell/AppShellDependencies.swift`** — `struct AppShellDependencies`, the slice of the bootstrap dependency graph `AppShell` actually consumes. Each target's full dependency struct (`SuperOSAppDependencies`, `SuperBibleAppDependencies`) exposes a `var shellDependencies` slicer that materializes one of these.
- **`App/Shell/AppShellLaunchBehavior.swift`** — `struct AppShellLaunchBehavior`, per-target cold-launch defaults for `AppShell`. Today's only knob is `initialChatState: ChatPresentationState`. SuperOS passes `.standard` (= `.expanded`); SuperBible passes `.minimized`. `AppShell.init` seeds both `_chatState` and the matching `_chatProgress` from it so the very first frame matches the per-target policy with no flicker. **Scope is cold launch only — no scene-phase handler.** Extend this struct if product ever wants force-snap semantics on foreground returns.
- **`App/Shell/AppBootstrapSupport.swift`** — namespaced static helpers shared by both bootstraps: `defaultDataDirectory()`, `ensureDirectoryExists(_:)`, `hydrateProviders(into:from:toolRegistry:appleFoundationAvailability:)`, and the DEBUG-only `seedDebugModelIfNeeded(repository:)`. Target-specific work (applet roster, chat briefing) stays in each bootstrap; only the generic plumbing is shared.
- **`App/Shell/FailureScreen.swift`** — inline error pane rendered by both the outer per-target content view (`SuperOSContentView` / `SuperBibleContentView`, for `.failed(_)`) and the inner `ChatLayer` (bootstrap-failed-after-launch path).
- **`App/Shell/FixedHamburgerButton.swift`** — top-left 36×36pt raised pill. Survives every chat-presentation-state transition unchanged.
- **`App/Shell/LazyConversationDriver.swift`** — `actor` wrapper around `ChatSessionDriver` that defers the conversation's first DB write until the user actually sends a message. Was at `App/LazyConversationDriver.swift` pre-SB-M1; relocated here so both targets reach it.

SuperOS-only placeholder applets (`AppletPlaceholderScreen`, `RecipesPlaceholderApplet`, `FinancePlaceholderApplet`) live under `App-SuperOS/Placeholders/`, never compiled into SuperBible.

Anything chat-overlay-specific (the three state shapes, the drag handle, the spring + reduce-motion tokens) lives in `Packages/Chat/Sources/Chat/UI/ChatOverlay/` — it's chat-related and travels with the Chat package so the chat overlay is reusable if the shell ever changes.

## Rules

- **Chat-the-overlay is not a registered applet.** It's the host. Don't register a backdrop applet with `appletID: "chat"` in either bootstrap — the searchable conversation-list backdrop is `ChatsApplet` (`appletID: "chats"`), and it's the only Chat-package applet that belongs in the registry. The sidebar always shows chat history + New Chat CTA; backdrop applets only render behind the chat overlay.
- **AppletRegistry mutation is composition-root only.** The shell can flip `registry.activeID` at runtime, but the `applets` list is fixed at app init. Dynamic install / uninstall flows from `docs/DESIGN.md §3.2-3.3` are deferred.
- **Default chat-presentation-state transitions** (`docs/DESIGN.md §4.4`):
  - Tap an applet from the sidebar → `chatState = .minimized` (chat collapses; backdrop owns the screen)
  - Tap a conversation in CHATS or tap New Chat → `chatState = .expanded` (focus mode)
  - Tap dimmed backdrop in semi-expanded → `chatState = .minimized` (user reclaims the applet)
  - Drag the chat surface anywhere / tap the pill body → handled by `ChatOverlay`, not here (the overlay tracks the finger continuously and snaps to the nearest anchor on release)
- **Reduce Motion must thread through.** Read `\.accessibilityReduceMotion` in `AppShell` and pass it to every `withAnimation(...)` block via `ChatOverlayAnimation.transition(reduceMotion:)`. The shell, the overlay container, and the backdrop's opacity all share the same animation curve so the transitions stay coherent.
- **Adding a new `App/Shell/*.swift` file? Add it to BOTH `project.yml` source lists.** Both targets now use explicit per-file entries for shared shell files (`Super.sources` and `SuperBible.sources` each list them). A missed entry breaks whichever target's list got skipped. CI's matrix legs (`build-app (Super)` and `build-app (SuperBible)`) catch this, but land it in the same diff.
- **Per-target launch defaults flow through `AppShellLaunchBehavior`.** The shell does NOT know which target it's running in; it reads `dependencies.launchBehavior` and seeds the cold-launch chat anchor accordingly. If you find yourself adding a `#if` or a target check inside `AppShell`, you're at the wrong layer — add the knob to `AppShellLaunchBehavior` and let each target's bootstrap configure it.

## Testing

- App-target Swift code does **not** currently have its own XCTest target. Closest existing coverage is `Packages/Chat/Tests/ChatTests/UI/Snapshots/ChatOverlaySnapshotTests.swift` (anchor-state heights + mid-drag intermediate × themes) — it snapshot-tests the chat-overlay surface directly, which is the load-bearing surface area.
- **Manual sim verification is the bar for changes here** until an app-target test target exists (tracked in `TODO.md` § SB-M1 follow-ups). Snapshot anything verifiable from inside the Chat package; for shell-only layout decisions (chrome z-order, backdrop opacity timing, sidebar plumbing) verify on iPhone 17 / iOS 26.4 / Xcode 26.4.1 — CI's pinned trio.
- **Verify both targets.** `xcodebuild build -scheme Super` and `xcodebuild build -scheme SuperBible` must both succeed locally before opening a PR that touches anything under `App/Shell/`.

## Dependencies

- `Core` — `MiniApplet`, `AppletRegistry`, `SuperEventBus`, `SplashView`, `SuperTheme`, `URLSessionHTTPClient`, `AppleFoundationAvailability`, etc.
- `Chat` — every Chat type the shell holds or constructs: `ChatScreenViewModel`, `SidebarViewModel`, `SettingsViewModel`, `ChatOverlay`, `SidebarDrawer`, `SettingsSheet`, `ChatSession*`, repositories, the `LLMProvider` family, `ModelConfigurationSeeding`, etc.
- `GRDBQuery` — the `DatabaseContext` `SettingsLayer` constructs for the memory pane.

The shared shell files don't import any specific applet package (`Bible`, `Todo`, `Plans`). Per-target bootstraps import the applet packages they register; the shell only sees opaque `any MiniApplet` values through the registry.
