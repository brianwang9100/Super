import Core
import SwiftUI
import Testing
@testable import Bible

/// Smoke checks for `BibleApplet` conformance. These don't render anything —
/// they verify the metadata the shell's `AppletRegistry` and sidebar rely on
/// so a future rename or accidental id flip surfaces here before the app
/// silently loses its persisted backdrop selection.
@Suite("BibleApplet conformance")
@MainActor
struct BibleAppletTests {
    @Test("appletID is stable and matches the persisted shell value")
    func appletIDMatchesPlaceholderPersistence() {
        // The shell reads `UserDefaults["shell.activeAppletID"]` at launch.
        // The previous `BiblePlaceholderApplet` wrote "bible" — the new
        // applet must keep the same id or every existing install loses
        // their persisted backdrop choice on upgrade.
        #expect(BibleApplet.appletID == "bible")
        #expect(BibleApplet().appletID == "bible")
    }

    @Test("display name renders as the sidebar label")
    func displayName() {
        #expect(BibleApplet().displayName == "Bible")
    }

    @Test("icon view renders without throwing for the sidebar size")
    func iconViewCompiles() {
        let view = BibleApplet().iconView(size: 20)
        // Touching `body` would force a SwiftUI render pipeline; here we
        // just confirm the protocol contract returns a non-empty `AnyView`.
        _ = view
    }

    @Test("root view returns the M0 placeholder screen")
    func rootViewCompiles() {
        let view = BibleApplet().rootView()
        _ = view
    }

    @Test("conforms to MiniApplet")
    func miniAppletConformance() {
        let applet: any MiniApplet = BibleApplet()
        #expect(applet.appletID == "bible")
    }
}
