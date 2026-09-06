# SuperOS App Target — Agent Rules

The composition root and target-specific assets for the **SuperOS** app — the founder's personal AI productivity app (the sibling of `App-SuperBible/`). Both apps share `Core`, `Chat`, `Bible`, and the shared shell at `App/Shell/`; each target lives in its own folder and registers its own applet set.

## Module identity

- **Bundle ID:** `com.brianwang.Super`
- **Display name:** `SuperOS` (App Store name; `PRODUCT_NAME` is `Super` because the App Store name `Super` was taken)
- **Composition root:** `SuperOSApp.swift` → `SuperOSAppBootstrap` → `SuperOSAppDependencies.shellDependencies` → shared `AppShell` (from `App/Shell/`)
- **Applet set:** Chats + Todo + Recipes (placeholder) + Bible + Finance (placeholder). Sidebar rail order leads with Chats; Todo is the cold-start default backdrop (decoupled from rail order — see below). See `SuperOSAppBootstrap.bootstrap()`.
- **Deployment target:** iOS 26.0

### Launch behavior

SuperOS uses `AppShellLaunchBehavior.standard`:

- **Chat overlay opens expanded.** Full-screen chat surface over the active backdrop on every cold launch. User drags down to reveal the backdrop.
- **Active backdrop is restored from `UserDefaults`.** `SuperOSAppBootstrap` reads `AppShell.activeAppletStorageKey` and resolves the backdrop via `AppletRegistry.resolveActiveID(applets:storedID:fallbackID:)`, falling back to `TodoApplet.appletID` (Todo) when there's nothing persisted. The fallback is pinned to Todo explicitly — **not** `applets.first` — so the rail can lead with Chats without changing the fresh-install landing surface. Mid-session picks (`onSelectApplet` in the shell) persist via the same key.

This is the default that `AppShellLaunchBehavior.standard` encodes — if you find yourself reading `UserDefaults` for the active applet, or constructing a launch-behavior struct outside this bootstrap, you're at the wrong layer.

## What lives here

- **`SuperOSApp.swift`** — `@main` entry. Owns the launch-state `@State` (`SuperOSBootstrapState`) and runs the bootstrap in a `.task` so any failure surfaces as the `FailureScreen` instead of a crashed launch.
- **`SuperOSAppBootstrap.swift`** — composition root. Defines `SuperOSAppDependencies` (the SuperOS-only dependency graph) and the `bootstrap()` static that wires the GRDB stack, repositories, tool/provider registries, the applet registry, the chat session store, and the per-target launch behavior. Calls into `AppBootstrapSupport` (in `App/Shell/`) for the generic plumbing shared with SuperBible.
- **`SuperOSContentView.swift`** — the SwiftUI view rendered by `WindowGroup`. Branches on `SuperOSBootstrapState` to show splash / failure / shell.
- **`Info.plist`** — SuperOS-specific Info.plist. Path is referenced by `project.yml`'s `Super.settings.base.INFOPLIST_FILE`.
- **`Assets.xcassets/`** — SuperOS-only assets (app icon, accent color, splash background).
- **`Placeholders/AppletPlaceholderScreen.swift`** — generic empty-state for unimplemented applets.
- **`Placeholders/PlaceholderApplets.swift`** — `RecipesPlaceholderApplet` and `FinancePlaceholderApplet` `MiniApplet` conformances. These never ship to SuperBible (deliberately omitted from `project.yml`'s `SuperBible.sources`).

## SuperOS-specific rules

These complement the root [`../AGENTS.md`](../AGENTS.md). When the root rules and these rules disagree, **these win for the SuperOS target.**

### Server-backed LLM transport

Per the root `AGENTS.md` § Backend, SuperOS's general policy is backend-proxied provider HTTP calls; SuperBible permits BYOK-direct calls. Apple's Foundation Models framework is the narrow exception: Local only runs on-device and Private Cloud Compute (PCC) uses Apple-managed transport with no API key. This does not authorize another direct HTTP transport. Fresh empty stores select local on iOS 26 and PCC on iOS 27+; populated stores preserve choices. Unavailable models must retain identity without automatic substitution.

### No account UI

Settings has no account row or identity capsule — the single-user MVP doesn't ship account flows, so `accountEmail` and the Settings account chip were removed from both targets (the `SettingsViewModel` no longer takes the parameter). Real identity will arrive with Sign in with Apple per the SuperBible fork spec §7; reintroduce account UI deliberately then rather than re-adding a hard-coded address.

## Testing expectations

Same as the root rules ([`../AGENTS.md`](../AGENTS.md) § Testing & Testability). App-target Swift code does not currently have its own XCTest target — manual verification uses the root's exact pinned Xcode 27 + iOS 27 simulator + iPhone 17 trio, plus iOS 26 compatibility checks. Shared shell snapshot coverage lives in `Packages/Chat/Tests/ChatTests/UI/Snapshots/`.
