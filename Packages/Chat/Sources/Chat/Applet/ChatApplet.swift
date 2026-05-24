import Core
import SwiftUI

/// `MiniApplet` conformance for Chat, retained primarily as a snapshot-test
/// fixture and as a reference implementation of `MiniApplet`.
///
/// **Not registered in production.** Chat is the shell's host surface, not
/// a backdrop applet — `AppShell` deliberately omits `ChatApplet()` from
/// its `AppletRegistry` (see `App/Shell/AGENTS.md`). The chat overlay
/// (`ChatOverlay`) is rendered directly by the shell and always
/// floats on top of whichever backdrop applet is active (or no backdrop
/// at all when `registry.activeID == nil`). If a future refactor needs
/// Chat to appear in the sidebar applet rail, prefer adding a "Chat" row
/// at the shell level rather than re-registering this conformance.
///
/// `rootView()` intentionally returns `Color.clear` because the type
/// exists only for protocol-shape consumers; the real chat UI is rendered
/// by `AppShell`, not from a registry-driven backdrop.
public struct ChatApplet: MiniApplet {
    /// Stable identifier referenced by the sidebar, deep-link router, and
    /// `AppletRegistry.activeID`.
    public static let appletID: String = "chat"

    public init() {}

    public var appletID: String { Self.appletID }

    public var displayName: String { "Chat" }

    public var accentColor: Color {
        // Primary accent green — Chat uses the shell's base palette by
        // design (`docs/DESIGN.md` §8.2 lists Chat's secondary accent as
        // the primary pastel green). We hand back the asset color named
        // `AccentColor` so the rail row matches the rest of the chrome.
        Color.accentColor
    }

    @MainActor
    public func iconView(size: CGFloat) -> AnyView {
        // Use the canonical 12-spoke spark — same glyph the empty-state
        // hero uses, scaled down for the sidebar rail row.
        AnyView(SparkIcon(size: size))
    }

    /// Intentionally empty. See type doc for why — the chat overlay is
    /// rendered by the shell, not by this applet's backdrop slot.
    @MainActor
    public func rootView() -> AnyView {
        AnyView(Color.clear)
    }

    /// Reads `Resources/DefaultSystemPrompt.md` for parity with the
    /// production load path (the host bootstrap reaches into the same bundle).
    /// Empty when the file is missing — `AppletRegistry.resolvedBriefings()`
    /// will then skip the block.
    public var systemPrompt: String {
        AppletSystemPrompt.load(from: .module, resource: "DefaultSystemPrompt")
    }
}
