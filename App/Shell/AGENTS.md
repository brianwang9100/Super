# App/Shell — Agent Guidelines

The shell that hosts every applet and overlays Chat on top in three presentation states. Lives inside the `Super` App target (not its own Swift Package) — these files are bundled with the app's composition root, not a reusable library.

## What lives here

- **`App/ContentView.swift`** — defines `AppShell` (the renamed `ChatHostView`). Owns the `AppletRegistry`, the `ChatPresentationState`, the sidebar / settings visibility bindings, and the per-conversation view-model rebuild path.
- **`App/Shell/FixedHamburgerButton.swift`** — top-left 36×36pt raised pill. Survives every chat-presentation-state transition unchanged.
- **`App/Shell/Placeholders/AppletPlaceholderScreen.swift`** — generic empty-state used by all four M2 placeholder applets (Todo, Recipes, Bible, Finance).
- **`App/Shell/Placeholders/PlaceholderApplets.swift`** — the four `MiniApplet` conformances registered with the shell at composition root.

Anything chat-overlay-specific (the three state shapes, the drag handle, the spring + reduce-motion tokens) lives in `Packages/Chat/Sources/Chat/UI/ChatOverlay/` — it's chat-related and travels with the Chat package so the chat overlay is reusable if the shell ever changes.

## Rules

- **Chat is not a registered applet.** It's the host. Don't add `ChatApplet()` back to the registry list in `AppShell`. The sidebar always shows chat history + New Chat CTA; backdrop applets only render behind the chat overlay.
- **AppletRegistry mutation is composition-root only.** The shell can flip `registry.activeID` at runtime, but the `applets` list is fixed at app init. Dynamic install / uninstall flows from `docs/DESIGN.md §3.2-3.3` are deferred.
- **Default chat-presentation-state transitions** (`docs/DESIGN.md §4.4`):
  - Tap an applet from the sidebar → `chatState = .minimized` (chat collapses; backdrop owns the screen)
  - Tap a conversation in CHATS or tap New Chat → `chatState = .expanded` (focus mode)
  - Tap dimmed backdrop in semi-expanded → `chatState = .minimized` (user reclaims the applet)
  - Drag the chat-surface handle / tap the minimized pill → handled by `ChatOverlayContainer`, not here
- **Reduce Motion must thread through.** Read `\.accessibilityReduceMotion` in `AppShell` and pass it to every `withAnimation(...)` block via `ChatOverlayAnimation.transition(reduceMotion:)`. The shell, the overlay container, and the backdrop's opacity all share the same animation curve so the transitions stay coherent.

## Testing

- App-target Swift code does **not** currently have its own XCTest target. The closest existing coverage is `Packages/Chat/Tests/ChatTests/UI/Snapshots/ChatOverlayContainerSnapshotTests.swift` (3 states × 3 themes) — it snapshot-tests the chat-overlay views directly, which is the load-bearing surface area.
- **Manual sim verification is the bar for changes here** until an App-target test target exists. Snapshot anything verifiable from inside the Chat package; for shell-only layout decisions (chrome z-order, backdrop opacity timing, sidebar plumbing) verify on iPhone 17 / iOS 26.4 / Xcode 26.4.1 — CI's pinned trio.
- An Xcode app-target test bundle is a candidate for a future PR. Until then, file paths under `App/Shell/` go through the same `xcodebuild build -scheme Super` check as the rest of the App target; compile errors will surface there.

## Dependencies

- `Core` — `MiniApplet`, `AppletRegistry`
- `Chat` — the chat surfaces (`ChatScreen`, `ChatOverlayContainer`, `MinimizedChatPill`, `SemiExpandedChatPanel`), the chat view models, the sidebar drawer, the settings sheet, the icon glyphs

No reverse imports — the shell never imports applet packages other than `Chat`. Placeholder applets are local to `App/Shell/Placeholders/` precisely so the shell doesn't pull in non-existent Todo / Recipes / Bible / Finance packages.
