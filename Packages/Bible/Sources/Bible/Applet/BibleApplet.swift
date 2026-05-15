import Core
import SwiftUI

/// The Bible mini-applet entry point. Registered with the shell's
/// `AppletRegistry` at composition root; the shell renders `rootView()`
/// behind the chat overlay.
///
/// M0 ships the placeholder backdrop only. Real chapter rendering, the
/// navigation bar, sheets, selection, and persistence land across the
/// remaining milestones.
public struct BibleApplet: MiniApplet {
    /// Stable, lowercase identifier — used for routing, settings keys, and
    /// deep-link URIs (`super://bible/<recordID>`). Must match the persisted
    /// `shell.activeAppletID` written by the previous `BiblePlaceholderApplet`
    /// so existing installs land on the same backdrop after the swap.
    public static let appletID: String = "bible"
    public var appletID: String { Self.appletID }
    public var displayName: String { "Bible" }
    /// Muted plum, matching the prior placeholder so the sidebar glyph and
    /// chat-card accent strips don't shift visually on upgrade. Exposed as
    /// a static so the package's own surfaces (e.g. `BibleScreen` in
    /// previews + snapshots) can read the same value without re-typing the
    /// triplet — M1's `SuperTheme` migration replaces the literal.
    public static let accentColor: Color = Color(red: 0.52, green: 0.32, blue: 0.55)
    public var accentColor: Color { Self.accentColor }

    public init() {}

    @MainActor
    public func iconView(size: CGFloat) -> AnyView {
        AnyView(BibleAppletIcon(size: size))
    }

    @MainActor
    public func rootView() -> AnyView {
        AnyView(BibleScreen())
    }
}
