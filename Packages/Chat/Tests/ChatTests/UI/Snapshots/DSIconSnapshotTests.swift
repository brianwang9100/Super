#if canImport(UIKit)
import Core
import Foundation
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
import UIKit
@testable import Chat

@Suite("DSIcon catalog snapshots", .serialized)
@MainActor
struct DSIconSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test(arguments: DSIcon.allCases)
    func assetLoadsAsTemplate(for icon: DSIcon) {
        guard let image = UIImage(named: icon.rawValue, in: DSIcon.resourceBundle, with: nil) else {
            Issue.record("Missing asset for DSIcon.\(icon) — expected \(icon.rawValue).imageset")
            return
        }
        #expect(
            image.renderingMode == .alwaysTemplate,
            "DSIcon.\(icon) is not template-rendered — fix template-rendering-intent in \(icon.rawValue).imageset/Contents.json"
        )
    }

    @Test("catalog grid renders all 32 icons — light")
    func catalogGridLight() {
        verify(theme: .vellumLight, name: "ds_icon_catalog_grid")
    }

    // Dark rendering exposes missing template intent as black strokes instead of tinted icons.
    @Test("catalog grid renders all 32 icons — dark")
    func catalogGridDark() {
        verify(theme: .vellumDark, name: "ds_icon_catalog_grid_dark")
    }

    private func verify(theme: SuperTheme.Identifier, name: String, function: String = #function) {
        let superTheme = SuperTheme.make(theme)
        let view = catalogGridView(foreground: superTheme.ink)
            .background(superTheme.background)
            .environment(\.colorScheme, superTheme.isDark ? .dark : .light)
            .frame(width: Self.gridWidth, height: Self.gridHeight)
        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: Self.gridWidth, height: Self.gridHeight)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }

    // MARK: - Grid layout

    private static let columns = 4
    private static let rows = (DSIcon.allCases.count + columns - 1) / columns
    private static let cellWidth: CGFloat = 100
    private static let cellHeight: CGFloat = 72
    private static let gridWidth: CGFloat = CGFloat(columns) * cellWidth
    private static let gridHeight: CGFloat = CGFloat(rows) * cellHeight

    private func catalogGridView(foreground: Color) -> some View {
        let cases = DSIcon.allCases
        return VStack(spacing: 0) {
            ForEach(0..<Self.rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<Self.columns, id: \.self) { col in
                        let index = row * Self.columns + col
                        if index < cases.count {
                            iconCell(cases[index], foreground: foreground)
                        } else {
                            Color.clear.frame(width: Self.cellWidth, height: Self.cellHeight)
                        }
                    }
                }
            }
        }
    }

    private func iconCell(_ icon: DSIcon, foreground: Color) -> some View {
        VStack(spacing: 6) {
            Image(dsIcon: icon)
                .resizable()
                .frame(width: 28, height: 28)
                .foregroundStyle(foreground)
            Text(icon.rawValue)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: Self.cellWidth, height: Self.cellHeight)
    }
}
#endif
