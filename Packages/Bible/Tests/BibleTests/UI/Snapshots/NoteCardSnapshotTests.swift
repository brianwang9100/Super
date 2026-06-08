#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `NoteCard` — one row in `NoteListSheet`. Variants cover a
/// user note (no footer) across the three themes, an assistant-written
/// note (provenance footer), and a long body that exercises the 4-line
/// clamp at default and Dynamic Type XXL so a font change can't silently
/// drop the ellipsis or the footer.
@Suite("NoteCard snapshots")
@MainActor
struct NoteCardSnapshotTests {
    /// Register Core's bundled brand fonts so the migrated JetBrains Mono /
    /// EB Garamond chrome faces resolve instead of baking the system
    /// fallback, and so this suite stays order-independent (registration is
    /// process-global; see `SnapshotFontRegistration`).
    init() { SnapshotFontRegistration.ensureRegistered() }

    private static let userBody = "This is the hinge of the whole gospel. \"God so loved the world\" — the love comes first, before anything is asked of us. Come back here when belief starts to feel like effort."

    private static let assistantBody = "The Greek here is monogenēs — \"one of a kind,\" not \"only-begotten\" in any biological sense. And v17 deliberately balances v16: the Son is sent not to condemn the world but so that it might be saved through him."

    private static let longBody = "There is a long tradition of reading this passage as comfort to the suffering, but the weight of it sits elsewhere: the love named here comes before any response is asked, before belief, before repentance, before the world knew to want it. That ordering is the whole gospel in miniature, and it is easy to invert under pressure and start reading the verse backwards, as though the loving were the reward for the believing."

    @Test("user note renders in the light theme")
    func userLight() {
        verify(theme: .light, date: "May 24, 2026", text: Self.userBody, author: nil, name: "user_light")
    }

    @Test("user note renders in the dark theme")
    func userDark() {
        verify(theme: .dark, date: "May 24, 2026", text: Self.userBody, author: nil, name: "user_dark")
    }

    @Test("user note renders in the sepia theme")
    func userSepia() {
        verify(theme: .sepia, date: "May 24, 2026", text: Self.userBody, author: nil, name: "user_sepia")
    }

    @Test("assistant note shows the provenance footer")
    func assistantLight() {
        verify(theme: .light, date: "May 28, 2026", text: Self.assistantBody, author: "Claude", name: "assistant_light")
    }

    @Test("assistant note shows the provenance footer in the dark theme")
    func assistantDark() {
        verify(theme: .dark, date: "May 28, 2026", text: Self.assistantBody, author: "Claude", name: "assistant_dark")
    }

    @Test("assistant note shows the provenance footer in the sepia theme")
    func assistantSepia() {
        verify(theme: .sepia, date: "May 28, 2026", text: Self.assistantBody, author: "Claude", name: "assistant_sepia")
    }

    @Test("a long body clamps to four lines with an ellipsis")
    func longBodyLight() {
        verify(theme: .light, date: "May 20, 2026", text: Self.longBody, author: nil, height: 180, name: "long_body_light")
    }

    @Test("a long body clamps to four lines at Dynamic Type XXL")
    func longBodyLightXXL() {
        verify(theme: .light, date: "May 20, 2026", text: Self.longBody, author: nil,
               height: 280, dynamicType: .xxLarge, name: "long_body_light_xxl")
    }

    @Test("an assistant note holds shape at Dynamic Type XXL")
    func assistantLightXXL() {
        verify(theme: .light, date: "May 28, 2026", text: Self.assistantBody, author: "Claude",
               height: 320, dynamicType: .xxLarge, name: "assistant_light_xxl")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        date: String,
        text: String,
        author: String?,
        height: CGFloat = 160,
        dynamicType: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        let view = ZStack {
            theme.background
            NoteCard(dateWritten: date, text: text, author: author)
                .padding(14)
        }
        .frame(width: 360, height: height)
        .superTheme(theme)
        .dynamicTypeSize(dynamicType)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 360, height: height)),
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
