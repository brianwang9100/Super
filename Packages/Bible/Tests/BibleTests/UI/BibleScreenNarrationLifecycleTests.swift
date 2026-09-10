#if canImport(UIKit)
import Core
import SwiftUI
import Testing
import UIKit
@testable import Bible

@Suite("BibleScreen narration lifecycle", .serialized)
@MainActor
struct BibleScreenNarrationLifecycleTests {
    @Test("leaving the reader stops narration even after its controls were dismissed")
    func leavingReaderStopsHiddenNarration() async {
        let service = FakeNarrationService()
        let model = BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            narration: NarrationController(service: service)
        )
        await model.load()
        let appeared = AsyncStream<Void>.makeStream()
        let disappeared = AsyncStream<Void>.makeStream()
        let host = UIHostingController(rootView: BibleScreen(viewModel: model)
            .onAppear { appeared.continuation.yield(()) }
            .onDisappear { disappeared.continuation.yield(()) })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            appeared.continuation.finish()
            disappeared.continuation.finish()
            model.narration.stop()
        }
        host.view.layoutIfNeeded()
        var appearance = appeared.stream.makeAsyncIterator()
        await appearance.next()

        model.startNarration()
        model.narration._simulateEvent(.started(verseNumber: 1))
        model.dismissNarrationSheet()
        #expect(model.narration.state == .speaking)
        #expect(service.stopCallCount == 0)

        window.rootViewController = nil
        var disappearance = disappeared.stream.makeAsyncIterator()
        await disappearance.next()

        #expect(!model.isNarrationSheetPresented)
        #expect(model.narration.state == .idle)
        #expect(service.stopCallCount == 1)
    }
}
#endif
