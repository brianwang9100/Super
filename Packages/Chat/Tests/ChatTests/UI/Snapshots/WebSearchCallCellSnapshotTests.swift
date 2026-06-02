#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Snapshots for `WebSearchCallCell` — the tool-call-style cell announcing a
/// web search above the grounded answer. Collapsed pins the header ("Web
/// search" + done badge + chevron); expanded pins the SYSTEM / QUERY / RESULTS
/// detail panels. Light / dark / sepia cover the themes; a Dynamic Type XXL
/// case pins reflow. Shares header typography with `ToolCallBlock` /
/// `SourceCitationsPill` (the cells deliberately read identically).
///
/// `.serialized` for the same `__Snapshots__/` PNG-write TOCTOU reason as the
/// other snapshot suites. Reduce Motion is not a separate variant — the cell
/// toggles `isExpanded` via a plain `Button` with no animation.
@Suite("WebSearchCallCell snapshots", .serialized)
@MainActor
struct WebSearchCallCellSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("collapsed, light")
    func collapsedLight() {
        verify(expanded: false, theme: .light, height: 70, name: "web_search_cell_collapsed_light")
    }

    @Test("collapsed, dark")
    func collapsedDark() {
        verify(expanded: false, theme: .dark, height: 70, name: "web_search_cell_collapsed_dark")
    }

    @Test("collapsed, sepia")
    func collapsedSepia() {
        verify(expanded: false, theme: .sepia, height: 70, name: "web_search_cell_collapsed_sepia")
    }

    @Test("expanded, light")
    func expandedLight() {
        verify(expanded: true, theme: .light, height: 190, name: "web_search_cell_expanded_light")
    }

    @Test("expanded, dark")
    func expandedDark() {
        verify(expanded: true, theme: .dark, height: 190, name: "web_search_cell_expanded_dark")
    }

    @Test("expanded, sepia")
    func expandedSepia() {
        verify(expanded: true, theme: .sepia, height: 190, name: "web_search_cell_expanded_sepia")
    }

    @Test("expanded dynamic type XXL")
    func expandedXXL() {
        verify(expanded: true, theme: .light, dynamicType: .xxLarge, height: 280, name: "web_search_cell_expanded_light_xxl")
    }

    private func verify(
        expanded: Bool,
        theme: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        height: CGFloat,
        name: String,
        function: String = #function
    ) {
        let view = WebSearchCallCell(
            system: "Native search",
            query: "latest mars rover news",
            sourceCount: 3,
            _isExpanded: expanded
        )
        .superTheme(.make(theme))
        .dynamicTypeSize(dynamicType)
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .frame(width: 402, height: height)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: height)),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}

#endif
