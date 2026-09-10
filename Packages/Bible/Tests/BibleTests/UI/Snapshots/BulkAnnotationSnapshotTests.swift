#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Bible

/// Glass uses SuperGlass's deterministic test fallback; real glass needs device verification.
@Suite("BulkAnnotation snapshots", .serialized)
@MainActor
struct BulkAnnotationSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    private static let coverage = AnnotationCoverage(books: 3, chapters: 38, verses: 1_204)

    private static func midRun() -> BulkRunSnapshot {
        BulkRunSnapshot(books: [romans(doneCount: 7, failAt: nil)], isRunning: true)
    }

    private static func failedRun() -> BulkRunSnapshot {
        BulkRunSnapshot(books: [romans(doneCount: 9, failAt: 6)], isRunning: true)
    }

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

    @Test("hub idle renders in vellum light / dark", arguments: [SuperTheme.Identifier.vellumLight, .vellumDark])
    func hubIdle(_ id: SuperTheme.Identifier) {
        let vm = makeViewModel()
        verify(theme: id, height: 700, name: "hub_idle_\(id.rawValue)") {
            BulkAnnotationHubScreen(viewModel: vm, coverage: Self.coverage, requiresCostConfirmation: true)
        }
    }

    @Test("hub with the single running job in vellum light / dark", arguments: [SuperTheme.Identifier.vellumLight, .vellumDark])
    func hubRunning(_ id: SuperTheme.Identifier) {
        let vm = makeViewModel(seed: Self.midRun())
        verify(theme: id, height: 700, name: "hub_running_\(id.rawValue)") {
            BulkAnnotationHubScreen(viewModel: vm, coverage: Self.coverage, requiresCostConfirmation: true)
        }
    }

    @Test("hub with a recently-finished list (idle) in vellum light / dark",
          arguments: [SuperTheme.Identifier.vellumLight, .vellumDark])
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

    // Include dismiss-only and retryable history rows.
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

    @Test("generate sheet with an expanded partial book in vellum light / dark",
          arguments: [SuperTheme.Identifier.vellumLight, .vellumDark])
    func generateSheet(_ id: SuperTheme.Identifier) {
        verify(theme: id, height: 760, name: "generate_\(id.rawValue)") { Self.generateSheet() }
    }

    @Test("generate sheet reflows at Dynamic Type XXL")
    func generateSheetXXL() {
        verify(theme: .vellumLight, dynamicType: .xxLarge, height: 920, name: "generate_light_xxl") {
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

    @Test("per-book progress mid-run in vellum light / dark", arguments: [SuperTheme.Identifier.vellumLight, .vellumDark])
    func progressMid(_ id: SuperTheme.Identifier) {
        let vm = makeViewModel(seed: Self.midRun())
        verify(theme: id, height: 760, name: "progress_mid_\(id.rawValue)") {
            BulkAnnotationProgressScreen(viewModel: vm)
        }
    }

    @Test("per-book progress with a failed chapter in vellum light / dark",
          arguments: [SuperTheme.Identifier.vellumLight, .vellumDark])
    func progressFailed(_ id: SuperTheme.Identifier) {
        let vm = makeViewModel(seed: Self.failedRun())
        verify(theme: id, height: 760, name: "progress_failed_\(id.rawValue)") {
            BulkAnnotationProgressScreen(viewModel: vm)
        }
    }

    @Test("per-book progress with skipped chapters in vellum light / dark",
          arguments: [SuperTheme.Identifier.vellumLight, .vellumDark])
    func progressSkipped(_ id: SuperTheme.Identifier) {
        let vm = makeViewModel(seed: Self.skippedRun())
        verify(theme: id, height: 760, name: "progress_skipped_\(id.rawValue)") {
            BulkAnnotationProgressScreen(viewModel: vm)
        }
    }

    @Test("per-book progress with skipped chapters reflows at Dynamic Type XXL")
    func progressSkippedXXL() {
        let vm = makeViewModel(seed: Self.skippedRun())
        verify(theme: .vellumLight, dynamicType: .xxLarge, height: 1000, name: "progress_skipped_light_xxl") {
            BulkAnnotationProgressScreen(viewModel: vm)
        }
    }

    @Test("per-book progress reflows at Dynamic Type XXL")
    func progressXXL() {
        let vm = makeViewModel(seed: Self.failedRun())
        verify(theme: .vellumLight, dynamicType: .xxLarge, height: 1000, name: "progress_failed_light_xxl") {
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

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: height)),
            named: name,
            testName: function
        )
        if let failure { Issue.record("\(name): \(failure)") }
    }
}
#endif
