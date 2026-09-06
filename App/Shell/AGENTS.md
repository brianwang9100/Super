# Shared Shell

Read [DESIGN.md](../../docs/DESIGN.md) for presentation states. These files compile directly into both app targets; they are not a Swift package.

- Add every new shared Swift file to **both** explicit source lists in `project.yml` (`Super` and `SuperBible`). Build both schemes before opening a PR; see [app-target verification](../../docs/TESTING.md#app-target-verification).
- The shared shell imports Core/Chat and receives opaque `any MiniApplet` values. Applet-specific imports, rosters, and briefings belong in each target's bootstrap. Shared bootstrap plumbing belongs in `AppBootstrapSupport`.
- Chat is the overlay host, not a registered backdrop. Register `ChatsApplet` with ID `"chats"`; never register a backdrop with ID `"chat"`. The registry's applet list is fixed at initialization; only `activeID` changes at runtime.
- Target-specific cold-launch policy flows through `AppShellLaunchBehavior`, never target checks in `AppShell`. Seed both chat state and progress from it; foreground returns preserve session state. Use `AppShell.activeAppletStorageKey` for persisted backdrop selection.
- Selecting an applet minimizes Chat; selecting a conversation/New Chat expands it; tapping the dimmed semi-expanded backdrop minimizes it. Dragging and pill taps belong to `ChatOverlay` in the Chat package.
- Shell animations use `ChatOverlayAnimation.transition(reduceMotion:)` with `accessibilityReduceMotion`, matching the overlay and backdrop curve.
