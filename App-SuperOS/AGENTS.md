# SuperOS Target

Personal app, scheme `Super`. Shared shell rules also apply when editing [App/Shell](../App/Shell/AGENTS.md).

- Cold launch opens Chat expanded and restores the backdrop through `AppShell.activeAppletStorageKey`. The fallback is explicitly Todo, independent of sidebar order. Configure this in `SuperOSAppBootstrap` using `AppShellLaunchBehavior.standard`.
- SuperOS currently uses the shared on-device provider setup and Keychain. Server-proxied transport and custom sync are future plans in [SERVER_ARCHITECTURE.md](../docs/SERVER_ARCHITECTURE.md) and [CLIENT_SERVER.md](../docs/CLIENT_SERVER.md), not an implemented dependency.
- No account UI in the single-user MVP. Keep Recipes/Finance placeholder applets in this target; they must not compile into SuperBible.
- Follow [app-target verification](../docs/TESTING.md#app-target-verification).
