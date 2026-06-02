#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `BibleTranslationSheet` — the translation picker across the
/// three themes. The sheet uses fixed type sizes (OS Dynamic Type support is
/// deferred app-wide), so no Dynamic Type variant is recorded.
@Suite("BibleTranslationSheet snapshots")
@MainActor
struct BibleTranslationSheetSnapshotTests {
    /// Register Core's bundled brand fonts so the migrated JetBrains Mono /
    /// Instrument Serif chrome faces resolve instead of baking the system
    /// fallback, and so this suite stays order-independent (registration is
    /// process-global; see `SnapshotFontRegistration`).
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("the picker renders in the light theme")
    func light() {
        verify(theme: .light, name: "light")
    }

    @Test("the picker renders in the dark theme")
    func dark() {
        verify(theme: .dark, name: "dark")
    }

    @Test("the picker renders in the sepia theme")
    func sepia() {
        verify(theme: .sepia, name: "sepia")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        let view = ZStack(alignment: .bottom) {
            theme.background
            BibleTranslationSheet(
                current: .kjv,
                bottomInset: 0,
                onSelect: { _ in },
                onClose: {}
            )
        }
        .frame(width: 402, height: 420)
        .superTheme(theme)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 420)),
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
