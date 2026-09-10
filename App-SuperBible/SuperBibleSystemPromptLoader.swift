import Core
import Foundation

/// Loads the app-bundled Bible persona, not Chat's generic SwiftPM resource.
enum SuperBibleSystemPromptLoader {
    /// Missing resources return an empty string in Release and assert in DEBUG.
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

    /// Missing compact resources fall back to the full persona in ChatSession;
    /// DEBUG asserts so a bundling error cannot silently lose compact-window savings.
    static func loadCompact() -> String {
        let body = AppletSystemPrompt.load(from: .main, resource: "SuperBibleSystemPrompt.compact")
        #if DEBUG
        if body.isEmpty {
            assertionFailure(
                "SuperBibleSystemPrompt.compact.md missing or empty in the App-SuperBible bundle. "
                + "Check the `buildPhase: resources` entry in `project.yml` for SuperBible."
            )
        }
        #endif
        return body
    }
}
