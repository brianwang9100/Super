import Chat

/// Applied only at cold launch; foreground returns preserve the current shell state.
struct AppShellLaunchBehavior: Sendable, Equatable {
    /// Only `.expanded` and `.minimized` are supported. `AppShell.init` rejects
    /// `.semiExpanded` because its initial progress requires container geometry.
    let initialChatState: ChatPresentationState

    static let standard = AppShellLaunchBehavior(initialChatState: .expanded)
}
