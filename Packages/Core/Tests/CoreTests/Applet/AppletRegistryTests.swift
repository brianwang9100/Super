import Foundation
import SwiftUI
import Testing
@testable import Core

/// Tests for `AppletRegistry.resolvedBriefings()` — applet-prompt fan-in
/// for the Chat leading-system-message stack.
@Suite("AppletRegistry")
@MainActor
struct AppletRegistryTests {
    @Test("resolvedBriefings sorts by appletID, not display name or input order")
    func sortsByAppletID() {
        let registry = AppletRegistry(applets: [
            FakeApplet(appletID: "todo", displayName: "Todo", prompt: "todo rules"),
            FakeApplet(appletID: "bible", displayName: "Bible", prompt: "bible rules"),
            FakeApplet(appletID: "finance", displayName: "Finance", prompt: "finance rules"),
        ])
        let briefings = registry.resolvedBriefings()
        #expect(briefings.map(\.label) == [
            "Bible applet",
            "Finance applet",
            "Todo applet",
        ])
    }

    @Test("Empty or whitespace-only prompts are skipped")
    func skipsEmptyBodies() {
        let registry = AppletRegistry(applets: [
            FakeApplet(appletID: "a", displayName: "A", prompt: "real"),
            FakeApplet(appletID: "b", displayName: "B", prompt: ""),
            FakeApplet(appletID: "c", displayName: "C", prompt: "   \n  "),
        ])
        let labels = registry.resolvedBriefings().map(\.label)
        #expect(labels == ["A applet"])
    }

    @Test("Bodies are trimmed of surrounding whitespace")
    func trimsBody() {
        let registry = AppletRegistry(applets: [
            FakeApplet(
                appletID: "todo",
                displayName: "Todo",
                prompt: "\n\n  Use ISO-8601 due dates.  \n\n"
            ),
        ])
        let body = registry.resolvedBriefings().first?.body
        #expect(body == "Use ISO-8601 due dates.")
    }

    @Test("Label is displayName + ' applet'")
    func labelFormat() {
        let registry = AppletRegistry(applets: [
            FakeApplet(appletID: "x", displayName: "ToDo List", prompt: "rules"),
        ])
        #expect(registry.resolvedBriefings().first?.label == "ToDo List applet")
    }

    @Test("Returns empty array when no applets contribute prompts")
    func emptyWhenAllSkipped() {
        let registry = AppletRegistry(applets: [
            FakeApplet(appletID: "a", displayName: "A", prompt: ""),
            FakeApplet(appletID: "b", displayName: "B", prompt: "  "),
        ])
        #expect(registry.resolvedBriefings().isEmpty)
    }
}

/// Bare-bones test conformance — only the fields touched by
/// `resolvedBriefings()` carry meaning; the rest exist to satisfy the
/// protocol.
@MainActor
private struct FakeApplet: MiniApplet {
    let appletID: String
    let displayName: String
    let prompt: String

    var accentColor: Color { .gray }
    var systemPrompt: String { prompt }

    func iconView(size: CGFloat) -> AnyView { AnyView(EmptyView()) }
    func rootView() -> AnyView { AnyView(EmptyView()) }
}
