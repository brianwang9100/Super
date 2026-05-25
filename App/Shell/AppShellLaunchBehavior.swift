import Chat

/// Per-target launch defaults for the shared `AppShell`. Each composition
/// root (`SuperOSAppBootstrap` / `SuperBibleAppBootstrap`) constructs one
/// of these and threads it through `AppShellDependencies.launchBehavior`.
///
/// Applies at cold launch only — the shell seeds its initial chat-overlay
/// state from these values in `init`. Mid-session state (drag, tap-to-
/// minimize, sidebar applet pick) is owned by the user and the shell;
/// foreground returns from background preserve whatever state the user
/// left in. To force snap-back semantics on every foreground transition,
/// add a scene-phase handler here — kept off until product needs it.
///
/// Designed as a value type so the SuperOS default (`AppShellLaunchBehavior
/// .standard`) lives next to the configuration surface, not buried inside
/// `AppShell` literals.
struct AppShellLaunchBehavior: Sendable, Equatable {
    /// Settled state of the chat overlay at cold launch. SuperOS uses
    /// `.expanded` (chat fills the screen over the user's last-used
    /// applet); SuperBible uses `.minimized` (Bible visible, chat as a
    /// pill).
    let initialChatState: ChatPresentationState

    /// SuperOS default: chat opens expanded over the user's last-used applet.
    static let standard = AppShellLaunchBehavior(initialChatState: .expanded)
}
