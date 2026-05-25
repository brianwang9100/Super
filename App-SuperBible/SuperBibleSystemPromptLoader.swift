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
    /// A missing resource silently resolves to the empty string (the
    /// behavior `AppletSystemPrompt.load` already provides). The chat
    /// orchestrator treats an empty briefing as "no per-applet block",
    /// so the worst case is the assistant falls back to the generic
    /// persona — not a crash.
    static func load() -> String {
        AppletSystemPrompt.load(from: .main, resource: "SuperBibleSystemPrompt")
    }
}
