import Core
import Foundation
import Testing
@testable import Chat

/// Tests for `BibleDeepLinkRouter`'s URL → event-bus dispatch. The
/// SwiftUI `OpenURLAction` wrapper is a thin shim around the same
/// function; covering the pure router keeps tests host-free.
@Suite("BibleDeepLinkRouter")
struct BibleDeepLinkRouterTests {
    @Test func validSuperBibleURLPublishesOpenRecord() async throws {
        let bus = SuperEventBus()
        let stream = await bus.events()
        var iterator = stream.makeAsyncIterator()

        let url = try #require(URL(string: "super://bible/verse?book=ROM&chapter=8&verses=28-30"))
        #expect(BibleDeepLinkRouter.handle(url: url, eventBus: bus))

        let event = await iterator.next()
        guard case .openRecord(let reference) = event else {
            Issue.record("expected .openRecord event, got \(String(describing: event))")
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
        // No subscriber ever sees an event — the bus has none.
        #expect(await bus.subscriberCount == 0)
    }

    @Test func malformedSuperBibleURLDoesNotHandle() async throws {
        let bus = SuperEventBus()
        // Missing chapter is structurally invalid per `BibleDeepLink`'s
        // parser; the router rejects so the URL falls back to the
        // system handler.
        let url = try #require(URL(string: "super://bible/verse?book=ROM"))
        #expect(BibleDeepLinkRouter.handle(url: url, eventBus: bus) == false)
    }

    @Test func nilBusStillHandlesToAvoidLeakingSchemeToSystem() async throws {
        // No bus wired (preview / snapshot host). The router still
        // reports the URL as handled so SwiftUI doesn't try to ask the
        // system to open a custom scheme with no app entry.
        let url = try #require(URL(string: "super://bible/verse?book=JHN&chapter=3&verses=16"))
        #expect(BibleDeepLinkRouter.handle(url: url, eventBus: nil))
    }
}
