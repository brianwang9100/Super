#if canImport(UIKit)
import Core
import Observation
import SwiftUI
import Testing
import UIKit
@testable import Bible

@Suite("BibleScreen narration lifecycle", .serialized)
@MainActor
struct BibleScreenNarrationLifecycleTests {
    @Test("dismissed narration publishes a reopen button and clears it when stopped", .timeLimit(.minutes(1)))
    func narrationAccessoryTracksPresentation() async throws {
        let service = FakeNarrationService()
        let model = BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            narration: NarrationController(service: service)
        )
        await model.load()
        let store = ComposerAccessoryStore()
        let host = UIHostingController(rootView: BibleScreen(viewModel: model)
            .composerAccessoryStore(store))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            model.narration.stop()
        }
        host.view.layoutIfNeeded()
        await waitForAccessories(store) { !$0.isEmpty }
        #expect(store.buttons.center == nil)

        model.startNarration()
        model.narration._simulateEvent(.started(verseNumber: 1))
        model.dismissNarrationSheet()
        await waitForAccessories(store) { $0.center != nil }

        try #require(store.buttons.center).action()
        #expect(model.isNarrationSheetPresented)
        #expect(model.narration.state == .speaking)
        #expect(service.startCallCount == 1)
        await waitForAccessories(store) { $0.center == nil }

        model.dismissNarrationSheet()
        await waitForAccessories(store) { $0.center != nil }
        model.narration.stop()
        await waitForAccessories(store) { $0.center == nil }
    }

    private func waitForAccessories(
        _ store: ComposerAccessoryStore,
        matching predicate: (ComposerAccessoryButtons) -> Bool
    ) async {
        while !predicate(store.buttons) {
            let changes = AsyncStream<Void>.makeStream()
            withObservationTracking {
                _ = store.buttons
            } onChange: {
                changes.continuation.yield(())
                changes.continuation.finish()
            }
            var iterator = changes.stream.makeAsyncIterator()
            await iterator.next()
        }
    }

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
        let store = ComposerAccessoryStore()
        let host = UIHostingController(rootView: BibleScreen(viewModel: model)
            .composerAccessoryStore(store)
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
        #expect(store.buttons.isEmpty)
    }
}
#endif
