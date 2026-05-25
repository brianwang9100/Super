import Core
import Foundation

/// Loads the SuperBible-flavor Chat system prompt from the app's main
/// bundle.
///
/// Lives in the App target (not a Swift Package), so `Bundle.main`
/// resolves to the `.app` itself — which is where xcodegen drops
/// `Resources/SuperBibleSystemPrompt.md` (via the explicit `buildPhase:
/// resources` entry in `project.yml`). The shared
/// `Core.AppletSystemPrompt.load(from:resource:)` helper does the
/// trimming + UTF-8 read.
///
/// The SuperOS target uses `ChatApplet().systemPrompt` instead, which
/// loads the generic `DefaultSystemPrompt.md` from the Chat SwiftPM
/// resource bundle — that file frames a general-purpose assistant; this
/// one frames a biblical-study companion.
enum SuperBibleSystemPromptLoader {
    /// Returns the biblical-study system prompt as a trimmed string.
    ///
    /// A missing resource resolves to the empty string in Release builds (the
    /// behavior `AppletSystemPrompt.load` already provides) so a botched
    /// resource bundle can't take down the running app. In DEBUG, the empty
    /// result trips an `assertionFailure` so the regression is impossible to
    /// miss during the dev-loop the moment the prompt drops out — without
    /// this, a future `project.yml` edit could silently strip the
    /// biblical-study persona without any compile or run signal.
    static func load() -> String {
        let body = AppletSystemPrompt.load(from: .main, resource: "SuperBibleSystemPrompt")
        #if DEBUG
        if body.isEmpty {
            assertionFailure(
                "SuperBibleSystemPrompt.md missing or empty in the App-SuperBible bundle. "
                + "Check the `buildPhase: resources` entry in `project.yml` for SuperBible."
            )
        }
        #endif
        return body
    }
}
