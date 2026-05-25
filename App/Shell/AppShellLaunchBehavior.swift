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
    ///
    /// Only `.expanded` and `.minimized` are supported today.
    /// `.semiExpanded` is rejected at `AppShell.init` time with a
    /// `preconditionFailure` — the right initial progress for that
    /// anchor depends on container geometry (it's not a literal), so
    /// wiring it as a launch state would need a second knob (e.g. a
    /// resolver closure or the named semi-anchor constant from
    /// `ChatOverlay`). Land that knob alongside any feature that needs
    /// `.semiExpanded` cold-launch.
    let initialChatState: ChatPresentationState

    /// SuperOS default: chat opens expanded over the user's last-used applet.
    static let standard = AppShellLaunchBehavior(initialChatState: .expanded)
}
