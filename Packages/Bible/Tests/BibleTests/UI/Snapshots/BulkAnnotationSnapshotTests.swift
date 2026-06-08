#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of the bulk-annotation surfaces — the Annotations hub (idle +
/// running), the Generate sheet (book/chapter picker + estimate), and per-book
/// progress (mid-run + partial failure). Covered across light / dark / sepia,
/// with a Dynamic Type XXL reflow pass on the text-heavy surfaces.
///
/// Glass controls render through the deterministic solid fallback inside the
/// test process (see `SuperGlass`); real glass is verified on-device.
@Suite("BulkAnnotation snapshots")
@MainActor
struct BulkAnnotationSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    private static let coverage = AnnotationCoverage(books: 3, chapters: 38, verses: 1_204)

    /// A mid-run Romans: chapters 1–7 done, 8 generating, the rest queued.
    private static func midRun() -> BulkRunSnapshot {
        BulkRunSnapshot(books: [romans(doneCount: 7, failAt: nil)], isRunning: true)
    }

    /// A partial-failure Romans: 9 done, chapter 6 failed.
    private static func failedRun() -> BulkRunSnapshot {
        BulkRunSnapshot(books: [romans(doneCount: 9, failAt: 6)], isRunning: true)
    }

    /// A preserve-mode Romans: chapters 1–3 skipped (already annotated), 4–9
    /// done, 10 generating, the rest queued — exercises the `.skipped` row.
    private static func skippedRun() -> BulkRunSnapshot {
        let notes = [9, 14, 11, 16, 12, 8, 13, 18, 10, 15, 7, 12, 9, 11, 14, 6]
        var chapters: [BulkChapterProgress] = []
        for n in 1...16 {
            let state: BulkUnitState
            if n <= 3 { state = .skipped }
            else if n <= 9 { state = .done }
            else if n == 10 { state = .generating }
            else { state = .queued }
            chapters.append(BulkChapterProgress(number: n, state: state, producedCount: notes[(n - 1) % notes.count]))
        }
        return BulkRunSnapshot(books: [BulkBookProgress(bookID: "ROM", name: "Romans", chapters: chapters)], isRunning: true)
    }

    private static func romans(doneCount: Int, failAt: Int?) -> BulkBookProgress {
        let notes = [9, 14, 11, 16, 12, 8, 13, 18, 10, 15, 7, 12, 9, 11, 14, 6]
        var chapters: [BulkChapterProgress] = []
        for n in 1...16 {
            let state: BulkUnitState
            if failAt == n { state = .failed }
            else if n <= doneCount { state = .done }
            else if n == doneCount + 1 { state = .generating }
            else { state = .queued }
            chapters.append(BulkChapterProgress(number: n, state: state, producedCount: notes[(n - 1) % notes.count]))
        }
        return BulkBookProgress(bookID: "ROM", name: "Romans", chapters: chapters)
    }

    private func makeViewModel(seed: BulkRunSnapshot? = nil) -> BulkAnnotationViewModel {
        let runner = FakeBulkAnnotationRunner(autoAdvance: false)
        let vm = BulkAnnotationViewModel(runner: runner)
        if let seed { runner.seed(seed) }
        return vm
    }

    // MARK: - Hub

    @Test("hub idle renders in light / dark / sepia", arguments: SuperTheme.Identifier.allCases)
    func hubIdle(_ id: SuperTheme.Identifier) {
        let vm = makeViewModel()
        verify(theme: id, height: 700, name: "hub_idle_\(id.rawValue)") {
            BulkAnnotationHubScreen(viewModel: vm, coverage: Self.coverage, requiresCostConfirmation: true)
        }
    }

    @Test("hub with the single running job in light / dark / sepia", arguments: SuperTheme.Identifier.allCases)
    func hubRunning(_ id: SuperTheme.Identifier) {
        let vm = makeViewModel(seed: Self.midRun())
        verify(theme: id, height: 700, name: "hub_running_\(id.rawValue)") {
            BulkAnnotationHubScreen(viewModel: vm, coverage: Self.coverage, requiresCostConfirmation: true)
        }
    }

    @Test("hub with a recently-finished list (idle) in light / dark / sepia",
          arguments: SuperTheme.Identifier.allCases)
    func hubFinished(_ id: SuperTheme.Identifier) {
        let vm = makeViewModel()
        verify(theme: id, height: 760, name: "hub_finished_\(id.rawValue)") {
            BulkAnnotationHubScreen(
                viewModel: vm,
                coverage: Self.coverage,
                requiresCostConfirmation: true,
                finishedRuns: Self.finishedRuns
            )
        }
    }

    /// One clean completion and one halted run — exercises both row variants
    /// (dismiss-only vs. dismiss + Retry, with a halt reason).
    private static let finishedRuns: [FinishedRunSummary] = [
        FinishedRunSummary(
            runID: "r1", status: .completed, haltReason: nil,
            completedAt: Date(timeIntervalSince1970: 200),
            bookNames: ["Romans", "Galatians"], producedCount: 124, failedCount: 0
        ),
        FinishedRunSummary(
            runID: "r2", status: .failed, haltReason: .quota,
            completedAt: Date(timeIntervalSince1970: 100),
            bookNames: ["1 Corinthians"], producedCount: 38, failedCount: 2
        ),
    ]

    // MARK: - Generate sheet

    @Test("generate sheet with an expanded partial book in light / dark / sepia",
          arguments: SuperTheme.Identifier.allCases)
    func generateSheet(_ id: SuperTheme.Identifier) {
        verify(theme: id, height: 760, name: "generate_\(id.rawValue)") { Self.generateSheet() }
    }

    @Test("generate sheet reflows at Dynamic Type XXL")
    func generateSheetXXL() {
        verify(theme: .light, dynamicType: .xxLarge, height: 920, name: "generate_light_xxl") {
            Self.generateSheet()
        }
    }

    @MainActor
    private static func generateSheet() -> some View {
        let runner = FakeBulkAnnotationRunner(autoAdvance: false)
        let vm = BulkAnnotationViewModel(runner: runner)
        vm.expandedBookIDs = ["ROM"]
        vm.fullyAnnotatedBookIDs = ["GAL"]
        vm.annotatedChapters = [ChapterRef(bookID: "ROM", number: 1), ChapterRef(bookID: "ROM", number: 2)]
        vm.toggleChapter(ChapterRef(bookID: "ROM", number: 3))
        vm.toggleChapter(ChapterRef(bookID: "ROM", number: 4))
        return GenerateAnnotationsSheet(viewModel: vm, requiresCostConfirmation: true)
    }

    // MARK: - Progress

    @Test("per-book progress mid-run in light / dark / sepia", arguments: SuperTheme.Identifier.allCases)
    func progressMid(_ id: SuperTheme.Identifier) {
        let vm = makeViewModel(seed: Self.midRun())
        verify(theme: id, height: 760, name: "progress_mid_\(id.rawValue)") {
            BulkAnnotationProgressScreen(viewModel: vm)
        }
    }

    @Test("per-book progress with a failed chapter in light / dark / sepia",
          arguments: SuperTheme.Identifier.allCases)
    func progressFailed(_ id: SuperTheme.Identifier) {
        let vm = makeViewModel(seed: Self.failedRun())
        verify(theme: id, height: 760, name: "progress_failed_\(id.rawValue)") {
            BulkAnnotationProgressScreen(viewModel: vm)
        }
    }

    @Test("per-book progress with skipped chapters in light / dark / sepia",
          arguments: SuperTheme.Identifier.allCases)
    func progressSkipped(_ id: SuperTheme.Identifier) {
        let vm = makeViewModel(seed: Self.skippedRun())
        verify(theme: id, height: 760, name: "progress_skipped_\(id.rawValue)") {
            BulkAnnotationProgressScreen(viewModel: vm)
        }
    }

    @Test("per-book progress reflows at Dynamic Type XXL")
    func progressXXL() {
        let vm = makeViewModel(seed: Self.failedRun())
        verify(theme: .light, dynamicType: .xxLarge, height: 1000, name: "progress_failed_light_xxl") {
            BulkAnnotationProgressScreen(viewModel: vm)
        }
    }

    // MARK: - Harness

    private func verify(
        theme themeID: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        height: CGFloat,
        name: String,
        function: String = #function,
        @ViewBuilder content: () -> some View
    ) {
        let theme = SuperTheme.make(themeID)
        let view = ZStack {
            theme.background
            content()
        }
        .frame(width: 393, height: height)
        .superTheme(theme)
        .dynamicTypeSize(dynamicType)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: height)),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure { Issue.record("\(name): \(failure)") }
    }
}
#endif
