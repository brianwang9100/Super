#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Snapshot baselines for ``CopyConfirmationPill`` — the transient
/// "Copied!" pill that floats above the composer after the user taps
/// Copy on an assistant message. Covers light/dark/sepia plus a
/// Dynamic Type XXL variant.
///
/// Reduce Motion is not recorded as a separate variant: the pill view
/// body has no `withAnimation`, no `.animation(...)`, and no
/// `.transition(...)` modifier. The animation that wraps it lives on
/// the parent `ChatScreen`'s `.overlay { … .transition(...) }` /
/// `.animation(...)` — not in this view. Same documented gap as
/// `MemoryUpdatedPillSnapshotTests`: steady-state frames are
/// pixel-identical regardless of `accessibilityReduceMotion`.
/// `.serialized` — snapshot baselines are read/written per-test against
/// the same on-disk `__Snapshots__/CopyConfirmationPillSnapshotTests/`
/// directory. Parallel execution races on the PNG files (TOCTOU on file
/// writes), not on any async behavior in the code under test —
/// serialization is the right tool here. Matches every other snapshot
/// suite in this directory; see `MemoryUpdatedPillSnapshotTests` for the
/// canonical justification.
@Suite("CopyConfirmationPill snapshots", .serialized)
@MainActor
struct CopyConfirmationPillSnapshotTests {
    private func host<V: View>(_ view: V, theme: SuperTheme.Identifier) -> some View {
        view
            .padding(16)
            .background(SuperTheme.make(theme).background)
            .superTheme(.make(theme))
    }

    private func recordOrCompare<V: View>(view: V, name: String, function: String = #function) {
        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .sizeThatFits),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure { Issue.record("\(name): \(failure)") }
    }

    @Test("pill — light")
    func pillLight() {
        recordOrCompare(
            view: host(CopyConfirmationPill(), theme: .light),
            name: "copy_pill_light"
        )
    }

    @Test("pill — dark")
    func pillDark() {
        recordOrCompare(
            view: host(CopyConfirmationPill(), theme: .dark),
            name: "copy_pill_dark"
        )
    }

    @Test("pill — sepia")
    func pillSepia() {
        recordOrCompare(
            view: host(CopyConfirmationPill(), theme: .sepia),
            name: "copy_pill_sepia"
        )
    }

    @Test("pill at Dynamic Type XXL")
    func pillXXL() {
        recordOrCompare(
            view: host(CopyConfirmationPill(), theme: .light)
                .dynamicTypeSize(.xxLarge),
            name: "copy_pill_light_xxl"
        )
    }
}
#endif
