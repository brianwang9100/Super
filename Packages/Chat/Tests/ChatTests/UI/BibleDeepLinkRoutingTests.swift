import Core
import Foundation
import Testing
@testable import Chat

@Suite("BibleDeepLinkRouter")
struct BibleDeepLinkRouterTests {
    @Test func validSuperBibleURLRequestsPreview() async throws {
        let bus = SuperEventBus()
        let stream = await bus.events()
        var iterator = stream.makeAsyncIterator()

        let url = try #require(URL(string: "super://bible/verse?book=ROM&chapter=8&verses=28-30"))
        #expect(BibleDeepLinkRouter.handle(url: url, eventBus: bus))

        let event = await iterator.next()
        guard case .previewRecord(let reference) = event else {
            Issue.record("expected .previewRecord event, got \(String(describing: event))")
            return
        }
        #expect(reference.appletID == "bible")
        #expect(reference.kind == "verseRange")
        #expect(reference.sourceID == "ROM/8/28-30")
        #expect(reference.displayLabel == "Romans 8:28-30")
    }

    @Test func httpsURLDoesNotHandleAndDoesNotPublish() async throws {
        let bus = SuperEventBus()
        let url = try #require(URL(string: "https://example.com/page"))
        #expect(BibleDeepLinkRouter.handle(url: url, eventBus: bus) == false)
        #expect(await bus.subscriberCount == 0)
    }

    @Test func malformedSuperBibleURLDoesNotHandle() async throws {
        let bus = SuperEventBus()
        let url = try #require(URL(string: "super://bible/verse?book=ROM"))
        #expect(BibleDeepLinkRouter.handle(url: url, eventBus: bus) == false)
    }

    @Test func nilBusStillHandlesToAvoidLeakingSchemeToSystem() async throws {
        // Preview hosts lack a bus; still consume custom URLs to avoid system handoff.
        let url = try #require(URL(string: "super://bible/verse?book=JHN&chapter=3&verses=16"))
        #expect(BibleDeepLinkRouter.handle(url: url, eventBus: nil))
    }
}
