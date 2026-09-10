#if canImport(UIKit)
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
import UIKit
@testable import Core

@Suite("SheetNavBar snapshots", .serialized)
@MainActor
struct SheetNavBarSnapshotTests {
    init() {
        Core.registerBundledFonts()
    }

    @Test("light")
    func light() {
        verify(theme: .vellumLight, name: "navbar_light")
    }

    @Test("dark")
    func dark() {
        verify(theme: .vellumDark, name: "navbar_dark")
    }

    @Test("trailing control keeps the title centered")
    func trailing() {
        // Keep sizing fixed here; fitsContent separately covers the inset change.
        let themeID = SuperTheme.Identifier.vellumLight
        let bar = SheetNavBar(title: "John 3", onClose: {}) {
            Image(systemName: "stop.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SuperTheme.make(themeID).ink)
                .frame(width: 44, height: 44)
        }
        verify(bar, theme: themeID, name: "navbar_trailing")
    }

    @Test("subtitle — light")
    func subtitleLight() {
        verify(subtitleBar(theme: .vellumLight), theme: .vellumLight, name: "navbar_subtitle_light")
    }

    @Test("subtitle — dark")
    func subtitleDark() {
        verify(subtitleBar(theme: .vellumDark), theme: .vellumDark, name: "navbar_subtitle_dark")
    }

    @Test("subtitle — font scale max grows the title and subtitle together")
    func subtitleFontScaleMax() {
        let view = chrome(subtitleBar(theme: .vellumLight), theme: .vellumLight)
            .superTypography(.make(.serif, fontScale: 1.20))
        record(view, named: "navbar_subtitle_font_scale_max_light", function: #function)
    }

    @Test("fitsContent pins the top inset to zero")
    func fitsContent() {
        verify(
            SheetNavBar(title: "Translation", sizing: .fitsContent, onClose: {}),
            theme: .vellumLight,
            name: "navbar_fits_content"
        )
    }

    @Test("a long title truncates within one line")
    func longTitle() {
        verify(
            SheetNavBar(title: "Ecclesiastes 12 · King James Version", onClose: {}),
            theme: .vellumLight,
            name: "navbar_long_title"
        )
    }

    @Test("dynamic type XXL leaves the bar layout stable")
    func dynamicTypeXXL() {
        let function = #function
        let view = chrome(
            SheetNavBar(title: "John 3", onClose: {}),
            theme: .vellumLight
        )
        .dynamicTypeSize(.xxLarge)

        // Dynamic Type must wrap the completed chrome, so bypass verify.
        record(view, named: "navbar_light_xxl", function: function)
    }

    @Test("font scale max — title scales with the slider")
    func fontScaleMax() {
        verifyFontScaleMax(theme: .vellumLight, name: "navbar_font_scale_max_light")
    }

    @Test("font scale max — title scales with the slider (dark)")
    func fontScaleMaxDark() {
        verifyFontScaleMax(theme: .vellumDark, name: "navbar_font_scale_max_dark")
    }

    // MARK: - Helpers

    private func subtitleBar(theme themeID: SuperTheme.Identifier) -> SheetNavBar<some View> {
        SheetNavBar(title: "1 Peter 2:1", subtitle: "1 Note", onClose: {}) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SuperTheme.make(themeID).ink)
                .frame(width: 44, height: 44)
        }
    }

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

    private func verifyFontScaleMax(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let view = chrome(SheetNavBar(title: "John 3", onClose: {}), theme: theme)
            .superTypography(.make(.serif, fontScale: 1.20))
        record(view, named: name, function: function, sourceLocation: sourceLocation)
    }

    // Top alignment makes the detent-specific inset visible.
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
        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 120)),
            named: named,
            testName: function
        )
        if let failure {
            // Report at the calling @Test, not this shared helper.
            Issue.record("\(named): \(failure)", sourceLocation: sourceLocation)
        }
    }
}
#endif
