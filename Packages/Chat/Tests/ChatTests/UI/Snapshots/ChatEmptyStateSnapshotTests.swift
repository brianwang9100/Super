#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Snapshots for the four time-of-day greetings rendered against each
/// theme. The greeting is injected directly so the test stays
/// deterministic without spinning up a `Clock`.
@Suite("ChatEmptyState snapshots", .serialized)
@MainActor
struct ChatEmptyStateSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("morning greeting in light")
    func morningLight() {
        verify(greeting: "How can I help you this morning?", theme: .vellumLight, name: "empty_morning_light")
    }

    @Test("afternoon greeting in dark")
    func afternoonDark() {
        verify(greeting: "How can I help you this afternoon?", theme: .vellumDark, name: "empty_afternoon_dark")
    }

    @Test("evening greeting in sepia")
    func eveningSepia() {
        verify(greeting: "How can I help you this evening?", theme: .sepiaLight, name: "empty_evening_sepia")
    }

    @Test("tonight greeting in light")
    func tonightLight() {
        verify(greeting: "How can I help you tonight?", theme: .vellumLight, name: "empty_tonight_light")
    }

    @Test("dynamic type XXL light")
    func dynamicTypeXXL() {
        let function = #function
        let view = ChatEmptyState(greeting: "How can I help you this morning?")
            .superTheme(.make(.vellumLight))
            .dynamicTypeSize(.xxLarge)
            .frame(width: 402, height: 600)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 600)),
            named: "empty_morning_light_xxl",
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure {
            Issue.record("empty_morning_light_xxl: \(failure)")
        }
    }

    private func verify(
        greeting: String,
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let view = ChatEmptyState(greeting: greeting)
            .superTheme(.make(theme))
            .frame(width: 402, height: 600)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 600)),
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
