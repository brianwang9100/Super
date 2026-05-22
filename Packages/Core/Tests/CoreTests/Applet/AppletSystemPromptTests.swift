import Foundation
import Testing
@testable import Core

/// Tests for `AppletSystemPrompt.load(from:resource:)` — the per-applet
/// bundled-markdown loader used by every `MiniApplet` conformance.
@Suite("AppletSystemPrompt")
struct AppletSystemPromptTests {
    @Test("Loads a bundled markdown file by default name")
    func loadsDefaultResource() {
        let body = AppletSystemPrompt.load(
            from: .module,
            resource: "FixtureSystemPrompt"
        )
        #expect(body.hasPrefix("Behavior rules for the fixture applet."))
        #expect(body.contains("Always greet the user by name"))
    }

    @Test("Returns empty string when resource is missing")
    func returnsEmptyForMissingResource() {
        let body = AppletSystemPrompt.load(
            from: .module,
            resource: "DoesNotExist"
        )
        #expect(body.isEmpty)
    }

    @Test("Trims leading and trailing whitespace")
    func trimsWhitespace() {
        let body = AppletSystemPrompt.load(
            from: .module,
            resource: "FixtureWithWhitespace"
        )
        #expect(body == "Leading and trailing whitespace gets trimmed.")
    }

    @Test("Honors the resource argument")
    func honorsResourceArgument() {
        let whitespace = AppletSystemPrompt.load(
            from: .module,
            resource: "FixtureWithWhitespace"
        )
        let main = AppletSystemPrompt.load(
            from: .module,
            resource: "FixtureSystemPrompt"
        )
        #expect(whitespace != main)
        #expect(!whitespace.isEmpty)
        #expect(!main.isEmpty)
    }
}
