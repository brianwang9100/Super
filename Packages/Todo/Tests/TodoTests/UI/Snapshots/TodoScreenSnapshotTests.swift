#if canImport(UIKit)
import Core
import GRDBQuery
import SnapshotTesting
import SwiftUI
import Testing
@testable import Todo

/// Snapshots for `TodoScreen` in its empty state — the "Tasks" header, the
/// zero-count caption, the filter pill, the floating add button, and the
/// empty-state copy.
///
/// Only the empty state is captured here: the screen binds its task list
/// through a reactive `@Query`, which has no synchronous first-value path,
/// so a `verifySnapshot` taken inline captures the empty `@Query` default.
/// The *populated* list rendering — grouped section headers and task rows —
/// is covered deterministically by `TodoSectionHeaderSnapshotTests` and
/// `TodoTaskRowSnapshotTests` instead.
@Suite("TodoScreen snapshots")
@MainActor
struct TodoScreenSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("empty, light") func emptyLight() throws {
        try verify(theme: .light, name: "screen_empty_light")
    }

    @Test("empty, dark") func emptyDark() throws {
        try verify(theme: .dark, name: "screen_empty_dark")
    }

    @Test("empty, sepia") func emptySepia() throws {
        try verify(theme: .sepia, name: "screen_empty_sepia")
    }

    // The screen scales its type through the app-wide `superFontScale`
    // slider rather than `@ScaledMetric`; this variant drives that path.
    @Test("empty, large font scale") func emptyLargeFontScale() throws {
        try verify(theme: .light, fontScale: 1.5, name: "screen_empty_light_large")
    }

    private func verify(
        theme: SuperTheme.Identifier,
        fontScale: CGFloat = 1,
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
        let view = TodoScreen(viewModel: viewModel)
            .databaseContext(.readWrite { database.queue })
            .frame(width: 402, height: 874)
            .background(resolved.background)
            .superTheme(resolved)
            .superFontScale(fontScale)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 874)),
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
