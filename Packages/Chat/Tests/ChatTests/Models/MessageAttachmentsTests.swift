import Core
import Foundation
import Testing
@testable import Chat

@Suite("MessageAttachments coding")
struct MessageAttachmentsTests {
    private func sampleReference() -> RecordReference {
        RecordReference(
            appletID: "bible",
            kind: "verseRange",
            sourceID: "WEB/JHN/3/16",
            displayLabel: "John 3:16",
            citation: "John 3:16 (WEB)",
            snapshot: "For God so loved the world…"
        )
    }

    @Test("Round-trips references through encode/decode")
    func roundTripsReferences() throws {
        let attachments = MessageAttachments(references: [sampleReference()])
        let json = MessageRecord.encode(attachments)
        #expect(json != nil)

        let record = MessageRecord(
            id: "m1", conversationId: "c1", role: .assistant,
            content: "hi", createdAt: Date(), attachmentsJSON: json
        )
        let decoded = record.attachments
        #expect(decoded?.references.count == 1)
        #expect(decoded?.references.first?.citation == "John 3:16 (WEB)")
    }

    @Test("Empty attachments encode to nil")
    func emptyEncodesToNil() {
        #expect(MessageRecord.encode(MessageAttachments()) == nil)
    }

    @Test("Decodes nil attachmentsJSON to nil")
    func decodesNilToNil() {
        let record = MessageRecord(
            id: "m1", conversationId: "c1", role: .assistant,
            content: "hi", createdAt: Date(), attachmentsJSON: nil
        )
        #expect(record.attachments == nil)
    }

    @Test("Round-trips web-search sources and suggestions HTML")
    func roundTripsSources() throws {
        let attachments = MessageAttachments(
            sources: [
                SourceCitation(
                    id: "s1",
                    title: "Peace of Westphalia",
                    url: URL(string: "https://example.com/westphalia")!,
                    snippet: "signed in 1648"
                ),
            ],
            searchSuggestionsHTML: "<div>chips</div>"
        )
        let json = MessageRecord.encode(attachments)
        #expect(json != nil)

        let record = MessageRecord(
            id: "m1", conversationId: "c1", role: .assistant,
            content: "hi", createdAt: Date(), attachmentsJSON: json
        )
        let decoded = record.attachments
        #expect(decoded?.sources.count == 1)
        #expect(decoded?.sources.first?.title == "Peace of Westphalia")
        #expect(decoded?.searchSuggestionsHTML == "<div>chips</div>")
        #expect(decoded?.references.isEmpty == true)
    }

    @Test("Round-trips the web-search query + system metadata")
    func roundTripsSearchMetadata() throws {
        let attachments = MessageAttachments(
            sources: [SourceCitation(id: "s1", title: "T", url: URL(string: "https://e.com")!)],
            searchQuery: "mars rover news",
            searchSystem: "Debug (mock)"
        )
        let json = MessageRecord.encode(attachments)
        let record = MessageRecord(
            id: "m1", conversationId: "c1", role: .assistant,
            content: "hi", createdAt: Date(), attachmentsJSON: json
        )
        let decoded = record.attachments
        #expect(decoded?.searchQuery == "mars rover news")
        #expect(decoded?.searchSystem == "Debug (mock)")
    }

    @Test("Search-metadata-only attachments are non-empty and persist")
    func searchMetadataOnlyPersists() {
        // A search with no results still has metadata worth persisting.
        let attachments = MessageAttachments(searchQuery: "q", searchSystem: "Native search")
        #expect(attachments.isEmpty == false)
        #expect(MessageRecord.encode(attachments) != nil)
    }

    @Test("Sources-only attachments are non-empty and persist")
    func sourcesOnlyPersists() {
        let attachments = MessageAttachments(sources: [
            SourceCitation(id: "s1", title: "T", url: URL(string: "https://e.com")!),
        ])
        #expect(attachments.isEmpty == false)
        #expect(MessageRecord.encode(attachments) != nil)
    }

    @Test("Legacy attachments JSON (no sources keys) still decodes")
    func legacyDecodes() throws {
        let legacyJSON = """
        {"references":[{"appletID":"bible","kind":"verseRange","sourceID":"WEB/JHN/3/16",\
        "id":"r1","displayLabel":"John 3:16","citation":"John 3:16 (WEB)","snapshot":"…"}]}
        """
        let record = MessageRecord(
            id: "m1", conversationId: "c1", role: .assistant,
            content: "hi", createdAt: Date(), attachmentsJSON: legacyJSON
        )
        let decoded = record.attachments
        #expect(decoded?.references.count == 1)
        #expect(decoded?.sources.isEmpty == true)
        #expect(decoded?.searchSuggestionsHTML == nil)
    }

    @Test("Malformed sources element degrades to [] without nuking references")
    func malformedSourcesDoesNotEraseReferences() throws {
        // Malformed sources must not discard the whole sidecar and its Bible references.
        let badJSON = """
        {"references":[{"appletID":"bible","kind":"verseRange","sourceID":"WEB/JHN/3/16",\
        "id":"r1","displayLabel":"John 3:16","citation":"John 3:16 (WEB)","snapshot":"…"}],\
        "sources":[{"id":"s1","title":"No URL here"}]}
        """
        let record = MessageRecord(
            id: "m1", conversationId: "c1", role: .assistant,
            content: "hi", createdAt: Date(), attachmentsJSON: badJSON
        )
        let decoded = record.attachments
        #expect(decoded != nil)
        #expect(decoded?.references.count == 1)
        #expect(decoded?.sources.isEmpty == true)
    }
}
