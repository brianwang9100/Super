import Core
import GRDBQuery
import SwiftUI

/// Root view of the Bookmarks mini-applet — the six fixed colour slots in a
/// single list, each showing its ribbon, colour name, and the chapter it
/// marks (translation-free: a bookmark marks the chapter, not an edition).
///
/// Reactive and view-model-free per the root persistence rule: the screen's
/// on-screen state *is* the `bibleBookmark` query, mutated from another
/// surface (the reader's assignment sheet), so it binds straight through a
/// GRDBQuery `@Query<AllBookmarksRequest>` rather than a pull-based load.
/// All six slots always render in `BibleBookmarkColor.allCases` order;
/// assigned rows are tappable and publish a chapter deep link on the shared
/// event bus, empty rows are muted and inert.
public struct BookmarksScreen: View {
    @Query<AllBookmarksRequest> private var bookmarks: [BibleBookmarkRecord]

    @Environment(\.superEventBus) private var environmentEventBus
    /// Unit-test-only override of the event bus. Production leaves this `nil`
    /// and the screen reads `@Environment(\.superEventBus)` from the shell;
    /// the test suite injects a real `SuperEventBus` to assert published
    /// payloads without constructing a SwiftUI host. Mirrors `ChatsScreen`.
    private let injectedEventBus: SuperEventBus?
    private var eventBus: SuperEventBus? { injectedEventBus ?? environmentEventBus }

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    /// Resolves a bookmark's `bookId` to its display name for the row's
    /// citation — the same catalog source the assignment sheet uses.
    private let catalog: BibleBookCatalog

    /// Bottom inset that clears the shell's minimized chat dock. Mirrors
    /// `ChatsScreen.chatDockClearance`.
    private static let chatDockClearance: CGFloat = 96

    /// - Parameters:
    ///   - catalog: book-name source for row citations; defaults to the
    ///     standard 66-book canon.
    ///   - eventBus: unit-test-only seam (see `injectedEventBus`). Production
    ///     leaves this `nil`.
    public init(
        catalog: BibleBookCatalog = .standard,
        eventBus: SuperEventBus? = nil
    ) {
        _bookmarks = Query(constant: AllBookmarksRequest())
        self.catalog = catalog
        self.injectedEventBus = eventBus
    }

    public var body: some View {
        ZStack(alignment: .top) {
            theme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                    // 48pt clears the shell's hamburger, matching ChatsScreen.
                    .padding(.top, 48)
                    .padding(.horizontal, 18)
                listSurface
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        Text("Bookmarks")
            .font(typography.display(36))
            .foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var listSurface: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(BibleBookmarkColor.allCases) { color in
                    row(for: color)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, Self.chatDockClearance)
        }
    }

    @ViewBuilder
    private func row(for color: BibleBookmarkColor) -> some View {
        if let record = assignment(for: color), let citation = citation(for: record) {
            BookmarksListRow(
                color: color,
                citation: citation,
                onTap: { _openBookmark(bookId: record.bookId, chapterNumber: record.chapterNumber) }
            )
        } else {
            BookmarksListRow(color: color, citation: nil, onTap: nil)
        }
    }

    /// The row currently marked by `color`, or `nil` when the slot is empty.
    /// A linear scan beats a keyed map at ≤6 rows.
    private func assignment(for color: BibleBookmarkColor) -> BibleBookmarkRecord? {
        bookmarks.first { $0.color == color }
    }

    /// `"John 3"`-style citation for an assigned slot, translation-free.
    /// `nil` for a `bookId` outside the catalog (can't happen for rows the
    /// reader wrote), which collapses the row to its empty presentation.
    private func citation(for record: BibleBookmarkRecord) -> String? {
        guard let book = catalog.book(id: record.bookId) else { return nil }
        return "\(book.name) \(record.chapterNumber)"
    }

    /// Publish an "open this chapter" request on the shared event bus,
    /// carrying a chapter-only `BibleDeepLink`. The shell routes
    /// `.openRecord` to the Bible applet, whose `BibleReferenceInbox` lands
    /// the reader. Internal (not private) so the unit-test suite can drive it
    /// directly; production fires it from the row tap. Returns the spawned
    /// publish `Task` so tests can `await` it before draining the bus.
    @discardableResult
    func _openBookmark(bookId: String, chapterNumber: Int) -> Task<Void, Never>? {
        guard let eventBus else { return nil }
        let reference = BibleDeepLink(bookId: bookId, chapter: chapterNumber).recordReference
        return Task { await eventBus.publish(.openRecord(reference: reference)) }
    }

    /// VoiceOver label for an assigned row, spelling out the tap outcome.
    static func rowLabel(color: BibleBookmarkColor, citation: String) -> String {
        "\(color.displayName) bookmark on \(citation). Open chapter"
    }
}
