#if canImport(UIKit)
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import Core

/// Snapshots for `SheetNavBar` — the shared reader-sheet header (glass `X` +
/// centered title + balancing trailing slot). Covers:
///
/// - the three themes, in the default `.expandable` sizing with no trailing
///   control (the book / translation / verse-action shape);
/// - a trailing-control variant, to guard that the fixed 44pt trailing slot
///   keeps the title optically centered (narration's Stop shape);
/// - a `.fitsContent` variant, which pins the nav bar's top inset to 0 instead
///   of 14 — the one visible difference the sizing axis owns;
/// - a long title, exercising `lineLimit(1)` + `minimumScaleFactor(0.8)`;
/// - a Dynamic Type XXL variant. The title resolves through
///   `typography.font(.body)`, which maps to a *fixed* `.system(size: 17)` (no
///   `relativeTo:`), so it deliberately does **not** scale with the OS text-size
///   setting — this variant is a layout-stability regression check that the bar
///   stays put under XXL, not an accessibility-scaling check.
///
/// The glass `X` renders its deterministic solid stand-in here (Liquid Glass
/// captures transparent in offscreen snapshots — see `SuperGlass.swift`).
@Suite("SheetNavBar snapshots")
@MainActor
struct SheetNavBarSnapshotTests {
    /// The title resolves to a system face, so brand-font registration isn't
    /// strictly required today — but registering keeps the suite robust if the
    /// title ever moves to the brand serif, and matches the other UI suites'
    /// process-global, idempotent setup.
    init() {
        Core.registerBundledFonts()
    }

    @Test("light")
    func light() {
        verify(theme: .light, name: "navbar_light")
    }

    @Test("dark")
    func dark() {
        verify(theme: .dark, name: "navbar_dark")
    }

    @Test("sepia")
    func sepia() {
        verify(theme: .sepia, name: "navbar_sepia")
    }

    @Test("trailing control keeps the title centered")
    func trailing() {
        // Default `.expandable` sizing so the only delta from `navbar_light` is
        // the trailing control; the zero-inset `.fitsContent` axis is owned
        // solely by the `fitsContent` test below.
        let bar = SheetNavBar(title: "John 3", onClose: {}) {
            Image(systemName: "stop.fill")
                .font(.system(size: 15, weight: .semibold))
                // Hardcoded to match `verify(theme: .light)` — keep in sync if
                // this variant is ever recorded under another theme.
                .foregroundStyle(SuperTheme.make(.light).ink)
                .frame(width: 44, height: 44)
        }
        verify(bar, theme: .light, name: "navbar_trailing")
    }

    @Test("fitsContent pins the top inset to zero")
    func fitsContent() {
        verify(
            SheetNavBar(title: "Translation", sizing: .fitsContent, onClose: {}),
            theme: .light,
            name: "navbar_fits_content"
        )
    }

    @Test("a long title truncates within one line")
    func longTitle() {
        verify(
            SheetNavBar(title: "Ecclesiastes 12 · King James Version", onClose: {}),
            theme: .light,
            name: "navbar_long_title"
        )
    }

    @Test("dynamic type XXL leaves the bar layout stable")
    func dynamicTypeXXL() {
        let function = #function
        let view = chrome(
            SheetNavBar(title: "John 3", onClose: {}),
            theme: .light
        )
        .dynamicTypeSize(.xxLarge)

        record(view, named: "navbar_light_xxl", function: function)
    }

    // MARK: - Helpers

    /// Default case: the no-trailing convenience init under `theme`.
    private func verify(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        verify(
            SheetNavBar(title: "John 3", onClose: {}),
            theme: theme,
            name: name,
            function: function,
            sourceLocation: sourceLocation
        )
    }

    private func verify(
        _ bar: SheetNavBar<some View>,
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        record(chrome(bar, theme: theme), named: name, function: function, sourceLocation: sourceLocation)
    }

    /// Pin the bar to the top of a themed card so its top inset (the one thing
    /// `SheetSizing` varies) is visible as the gap above it.
    private func chrome(_ bar: SheetNavBar<some View>, theme themeID: SuperTheme.Identifier) -> some View {
        let theme = SuperTheme.make(themeID)
        return VStack(spacing: 0) {
            bar
            Spacer(minLength: 0)
        }
        .frame(width: 402, height: 120)
        .background(theme.background)
        .superTheme(theme)
    }

    private func record(
        _ view: some View,
        named: String,
        function: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 120)),
            named: named,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure {
            // Report at the calling @Test, not this shared helper.
            Issue.record("\(named): \(failure)", sourceLocation: sourceLocation)
        }
    }
}
#endif
