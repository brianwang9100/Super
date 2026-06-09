import SwiftUI
import Testing
@testable import Core

/// Tests for `SuggestedChatAction.merged` (the shell's applet-fan-in helper)
/// and the `MiniApplet` no-actions default.
@Suite("SuggestedChatAction")
struct SuggestedChatActionTests {
    @Test("merged flattens per-applet lists in registration order")
    func flattensInOrder() {
        let merged = SuggestedChatAction.merged([
            [SuggestedChatAction(label: "A", message: "a")],
            [SuggestedChatAction(label: "B", message: "b"), SuggestedChatAction(label: "C", message: "c")],
        ])
        #expect(merged.map(\.label) == ["A", "B", "C"])
    }

    @Test("merged drops later duplicate labels, keeping the first occurrence")
    func dedupesByLabel() {
        let merged = SuggestedChatAction.merged([
            [SuggestedChatAction(label: "Dup", message: "first")],
            [SuggestedChatAction(label: "Dup", message: "second"), SuggestedChatAction(label: "B", message: "b")],
        ])
        #expect(merged.map(\.label) == ["Dup", "B"])
        #expect(merged.first?.message == "first")
    }

    @Test("merged caps at the limit, preserving order")
    func capsAtLimit() {
        let lists = [(0..<10).map { SuggestedChatAction(label: "L\($0)", message: "m\($0)") }]
        let merged = SuggestedChatAction.merged(lists, limit: 4)
        #expect(merged.map(\.label) == ["L0", "L1", "L2", "L3"])
    }

    @Test("merged returns empty for empty input")
    func emptyInput() {
        #expect(SuggestedChatAction.merged([]).isEmpty)
        #expect(SuggestedChatAction.merged([[], []]).isEmpty)
    }

    @Test("id is the label")
    func idIsLabel() {
        #expect(SuggestedChatAction(label: "X", message: "y").id == "X")
    }

    @Test("MiniApplet contributes no actions by default")
    @MainActor
    func defaultIsEmpty() {
        #expect(MinimalApplet().suggestedChatActions.isEmpty)
    }
}

/// A `MiniApplet` that overrides nothing optional — exercises the
/// `suggestedChatActions` default.
@MainActor
private struct MinimalApplet: MiniApplet {
    var appletID: String { "min" }
    var displayName: String { "Min" }
    var accentColor: Color { .gray }
    var systemPrompt: String { "" }
    func iconView(size: CGFloat) -> AnyView { AnyView(EmptyView()) }
    func rootView() -> AnyView { AnyView(EmptyView()) }
}
