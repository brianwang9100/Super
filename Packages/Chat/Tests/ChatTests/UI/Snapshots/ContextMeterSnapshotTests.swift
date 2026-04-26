#if canImport(UIKit)
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Coverage on `ContextMeter` across fill ratios. Three points anchor
/// the visual: empty, half-full, and over the model's window.
@Suite("ContextMeter snapshots", .serialized)
@MainActor
struct ContextMeterSnapshotTests {
    @Test("empty meter")
    func empty() {
        verify(used: 0, max: 32_000, theme: .light, name: "meter_empty_light")
    }

    @Test("half full")
    func halfFull() {
        verify(used: 16_000, max: 32_000, theme: .dark, name: "meter_half_dark")
    }

    @Test("over budget")
    func overBudget() {
        verify(used: 40_000, max: 32_000, theme: .sepia, name: "meter_over_sepia")
    }

    @Test("dynamic type XXL light")
    func dynamicTypeXXL() {
        let function = #function
        let view = ContextMeter(usedTokens: 16_000, maxTokens: 32_000)
            .superTheme(.make(.light))
            .dynamicTypeSize(.xxLarge)
            .padding(20)
        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .sizeThatFits),
            named: "meter_half_light_xxl",
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure {
            Issue.record("meter_half_light_xxl: \(failure)")
        }
    }

    private func verify(
        used: Int,
        max: Int,
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let view = ContextMeter(usedTokens: used, maxTokens: max)
            .superTheme(.make(theme))
            .padding(20)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .sizeThatFits),
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
