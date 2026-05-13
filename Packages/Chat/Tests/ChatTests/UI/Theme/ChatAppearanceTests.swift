import SwiftUI
import Testing
@testable import Chat

/// Tests for `ChatAppearance` — pins the "comfortable defaults equal the
/// pre-`ChatAppearance` hardcoded values" invariant so a future tweak to
/// the density-derived constants is caught here rather than only by
/// re-recorded snapshots. Also covers the density-switch arms so a
/// dropped case fails fast.
@Suite("ChatAppearance")
struct ChatAppearanceTests {
    @Test("default appearance matches the pre-wiring hardcoded values")
    func defaultMatchesPriorHardcodedRender() {
        let a = ChatAppearance.default
        #expect(a.fontScale == 1.0)
        #expect(a.density == .comfortable)
        // Body size: pre-change `FontSize(15)` and `.font(.system(.subheadline))` at default Dynamic Type.
        #expect(a.bodyFontSize == 15)
        // Paragraph line-spacing: pre-change `.relativeLineSpacing(.em(0.18))`.
        #expect(a.paragraphLineSpacingEm == 0.18)
        // Bubble inner padding: pre-change `.padding(.vertical, 10)` on UserBubble.
        #expect(a.bubbleInnerVerticalPadding == 10)
        // Bubble row padding: pre-change `.padding(.vertical, 4)` on UserBubble.
        #expect(a.bubbleRowVerticalPadding == 4)
        // Assistant row padding: pre-change `.padding(.vertical, 2)` on AssistantMessage / StreamingTail.
        #expect(a.assistantRowVerticalPadding == 2)
    }

    @Test("fontScale extremes resolve to the documented 0.85× / 1.15× body size")
    func fontScaleEndpointsScaleBodySize() {
        #expect(ChatAppearance(fontScale: 0.85, density: .comfortable).bodyFontSize == 15 * 0.85)
        #expect(ChatAppearance(fontScale: 1.15, density: .comfortable).bodyFontSize == 15 * 1.15)
    }

    @Test("density steps drive line-spacing monotonically")
    func densityLineSpacingIsMonotonic() {
        let compact = ChatAppearance(fontScale: 1.0, density: .compact).paragraphLineSpacingEm
        let comfortable = ChatAppearance(fontScale: 1.0, density: .comfortable).paragraphLineSpacingEm
        let spacious = ChatAppearance(fontScale: 1.0, density: .spacious).paragraphLineSpacingEm
        #expect(compact < comfortable)
        #expect(comfortable < spacious)
    }

    @Test("density steps drive bubble-row padding monotonically")
    func densityRowPaddingIsMonotonic() {
        let compact = ChatAppearance(fontScale: 1.0, density: .compact)
        let comfortable = ChatAppearance(fontScale: 1.0, density: .comfortable)
        let spacious = ChatAppearance(fontScale: 1.0, density: .spacious)
        #expect(compact.bubbleRowVerticalPadding < comfortable.bubbleRowVerticalPadding)
        #expect(comfortable.bubbleRowVerticalPadding < spacious.bubbleRowVerticalPadding)
        #expect(compact.bubbleInnerVerticalPadding < comfortable.bubbleInnerVerticalPadding)
        #expect(comfortable.bubbleInnerVerticalPadding < spacious.bubbleInnerVerticalPadding)
        #expect(compact.assistantRowVerticalPadding < comfortable.assistantRowVerticalPadding)
        #expect(comfortable.assistantRowVerticalPadding < spacious.assistantRowVerticalPadding)
    }

    @Test("Equatable conformance honors both knobs")
    func equality() {
        let a = ChatAppearance(fontScale: 1.0, density: .comfortable)
        let b = ChatAppearance(fontScale: 1.0, density: .comfortable)
        let differentScale = ChatAppearance(fontScale: 1.05, density: .comfortable)
        let differentDensity = ChatAppearance(fontScale: 1.0, density: .spacious)
        #expect(a == b)
        #expect(a != differentScale)
        #expect(a != differentDensity)
    }
}
