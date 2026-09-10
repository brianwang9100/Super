#if canImport(UIKit)
import Core
import GRDBQuery
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Todo

/// Only the empty state can be captured here: the screen binds its task list
/// through a reactive `@Query`, which has no synchronous first-value path,
/// so a `verifySnapshot` taken inline captures the empty `@Query` default.
/// Component suites cover the populated list deterministically.
@Suite("TodoScreen snapshots", .serialized)
@MainActor
struct TodoScreenSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("empty, light") func emptyLight() throws {
        try verify(theme: .vellumLight, name: "screen_empty_light")
    }

    @Test("empty, dark") func emptyDark() throws {
        try verify(theme: .vellumDark, name: "screen_empty_dark")
    }

    // The screen scales its type through the app-wide `superFontScale`
    // slider rather than `@ScaledMetric`; this variant drives that path.
    @Test("empty, large font scale") func emptyLargeFontScale() throws {
        try verify(theme: .vellumLight, fontScale: 1.5, name: "screen_empty_light_large")
    }

    // The toast layer renders in a bottom overlay. These variants pin a
    // toast so its resting position is captured — it must sit clear of
    // the bottom edge where the shell docks its minimized chat bar, not
    // flush against it — across all themes so its dark pill stays legible.
    @Test("toast, light") func toastVisible() throws {
        try verify(theme: .vellumLight, toast: "Saved", name: "screen_toast")
    }

    @Test("toast, dark") func toastVisibleDark() throws {
        try verify(theme: .vellumDark, toast: "Saved", name: "screen_toast_dark")
    }

    private func verify(
        theme: SuperTheme.Identifier,
        fontScale: CGFloat = 1,
        toast: String? = nil,
        name: String,
        function: String = #function
    ) throws {
        let database = try TodoDatabase.makeInMemory()
        let resolved = SuperTheme.make(theme)
        let viewModel = TodoScreenViewModel(
            taskRepository: GRDBTaskRepository(database: database),
            labelRepository: GRDBLabelRepository(database: database),
            joinRepository: GRDBTaskLabelRepository(database: database),
            clock: FixedClock(now),
            ids: DeterministicIDGenerator(prefix: "id-")
        )
        if let toast {
            viewModel.toast = TodoToastMessage(id: "toast-1", text: toast)
        }
        let view = TodoScreen(viewModel: viewModel)
            .databaseContext(.readWrite { database.queue })
            .frame(width: 402, height: 874)
            .background(resolved.background)
            .superTheme(resolved)
            .superFontScale(fontScale)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 874)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
