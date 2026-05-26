#if canImport(UIKit)
import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import Chat

/// Pins the design-system icon catalog (`Icons.xcassets`) against the
/// `ds/ds-icons.jsx` source. The asset-existence assertion catches typos
/// and missing `.imageset` directories at test time rather than as silent
/// "no such image" runtime warnings; the grid snapshot pins the rendered
/// shape of every icon so an unintended SVG edit (or a regression in
/// template-rendering) fails the test instead of slipping through
/// per-call-site snapshots one at a time.
@Suite("DSIcon catalog snapshots")
@MainActor
struct DSIconSnapshotTests {

    /// Every `DSIcon` case resolves to a loadable template asset in
    /// Chat's `Icons.xcassets`. Failure here is almost always one of:
    /// (a) the case's `rawValue` doesn't match the `.imageset` directory
    /// name, (b) the imageset's `Contents.json` is malformed, or (c) the
    /// asset isn't marked template — fix `template-rendering-intent` in
    /// `Contents.json` for that imageset.
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

    /// Pixel-stable snapshot of the full 32-icon catalog at 28pt on a
    /// light background. A single baseline covers every icon's geometry;
    /// any unintended SVG edit (path drift, stroke-width change, missing
    /// glyph) registers as a diff in this one test.
    @Test("catalog grid renders all 32 icons — light")
    func catalogGridLight() {
        verify(scheme: .light, name: "ds_icon_catalog_grid")
    }

    /// Dark-mode counterpart per AGENTS.md §Testing.3 (`light + dark` is
    /// required for new SwiftUI snapshots). Template-rendered icons keep
    /// their geometry across schemes, so this baseline mirrors the light
    /// one structurally — but it catches the failure mode that a pure
    /// light snapshot misses: an asset that silently loses its
    /// `template-rendering-intent` renders pure-black-stroke in dark
    /// mode instead of tinting white, which only a dark baseline pins.
    @Test("catalog grid renders all 32 icons — dark")
    func catalogGridDark() {
        verify(scheme: .dark, name: "ds_icon_catalog_grid_dark")
    }

    private func verify(scheme: ColorScheme, name: String, function: String = #function) {
        let background: Color = scheme == .dark ? .black : .white
        let foreground: Color = scheme == .dark ? .white : .black
        let view = catalogGridView(foreground: foreground)
            .background(background)
            .environment(\.colorScheme, scheme)
            .frame(width: Self.gridWidth, height: Self.gridHeight)
        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: Self.gridWidth, height: Self.gridHeight)),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }

    // MARK: - Grid layout

    private static let columns = 4
    /// Derived from `DSIcon.allCases.count` so the grid expands automatically
    /// when a new icon is added — a hardcoded row count silently routes the
    /// new icon to `Color.clear` and skips it from visual validation.
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
