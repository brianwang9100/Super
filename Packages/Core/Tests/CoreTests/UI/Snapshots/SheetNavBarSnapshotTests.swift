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
/// - a subtitle variant (the annotation / note-list shape), where a small
///   centered caption stacks under the title beside a trailing control;
/// - a `.fitsContent` variant, which pins the nav bar's top inset to 0 instead
///   of 14 — the one visible difference the sizing axis owns;
/// - a long title, exercising `lineLimit(1)` + `minimumScaleFactor(0.8)`;
/// - a Dynamic Type XXL variant. The title resolves through
///   `typography.font(.body)`, which maps to a *fixed* `.system(size: 17)` (no
///   `relativeTo:`), so it deliberately does **not** scale with the OS text-size
///   setting — this variant is a layout-stability regression check that the bar
///   stays put under XXL, not an accessibility-scaling check;
/// - a font-scale-max variant across the three themes. The same `.body` title
///   *does* track the app font-scale slider (`size × fontScale`), so this grows
///   the title at the `1.20` maximum — the live counterpart to the inert OS
///   Dynamic Type axis above.
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
        verify(theme: .vellumLight, name: "navbar_light")
    }

    @Test("dark")
    func dark() {
        verify(theme: .vellumDark, name: "navbar_dark")
    }

    @Test("sepia")
    func sepia() {
        verify(theme: .sepiaLight, name: "navbar_sepia")
    }

    @Test("trailing control keeps the title centered")
    func trailing() {
        // Default `.expandable` sizing so the only delta from `navbar_light` is
        // the trailing control; the zero-inset `.fitsContent` axis is owned
        // solely by the `fitsContent` test below. One `themeID` local ties the
        // trailing ink and the snapshot theme together so they can't drift.
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

    @Test("subtitle — sepia")
    func subtitleSepia() {
        verify(subtitleBar(theme: .sepiaLight), theme: .sepiaLight, name: "navbar_subtitle_sepia")
    }

    @Test("subtitle — font scale max grows the title and subtitle together")
    func subtitleFontScaleMax() {
        // The subtitle tracks the app font-scale slider just like the title, so
        // the `1.20` maximum grows both. Locks that the caption scales *with*
        // the title (not independently) — the live counterpart to the inert OS
        // Dynamic Type axis the bar deliberately opts out of.
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

        // `.dynamicTypeSize` must wrap the fully-chromed view, so this test
        // bypasses `verify()` and calls `record()` on the wrapped view directly.
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

    @Test("font scale max — title scales with the slider (sepia)")
    func fontScaleMaxSepia() {
        verifyFontScaleMax(theme: .sepiaLight, name: "navbar_font_scale_max_sepia")
    }

    // MARK: - Helpers

    /// The annotation / note-list shape: a title, a small centered caption
    /// (note count / "ANNOTATIONS" label), and a trailing control. Built per
    /// theme so the trailing glyph's ink matches the snapshot theme.
    private func subtitleBar(theme themeID: SuperTheme.Identifier) -> SheetNavBar<some View> {
        SheetNavBar(title: "1 Peter 2:1", subtitle: "1 Note", onClose: {}) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SuperTheme.make(themeID).ink)
                .frame(width: 44, height: 44)
        }
    }

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

    /// The title routes through `typography.font(.body)` at the default
    /// `tracksFontScale: true`, so the app font-scale slider (a global size
    /// control) grows it — 17 → 17 × 1.20 — independent of OS Dynamic Type.
    /// This records a dedicated `navbar_font_scale_max_<theme>` baseline that
    /// must differ from the `fontScale == 1.0` variants: the *live* counterpart
    /// to the inert OS Dynamic Type axis the XXL test locks. `1.20` is the
    /// slider's documented maximum (`SuperFontScale`).
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
