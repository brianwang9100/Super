import Chat
import Core
import SwiftUI

/// Minimal preview host; never opens databases, credentials, or live services.
@main
struct PreviewPilotApp: App {
    init() { Core.registerBundledFonts() }

    var body: some Scene {
        WindowGroup { Color.clear }
    }
}
