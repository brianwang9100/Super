import Core
import GRDBQuery
import SwiftUI

public struct BookmarksScreen: View {
    @Query<AllBookmarksRequest> private var bookmarks: [BibleBookmarkRecord]

    @Environment(\.superEventBus) private var environmentEventBus
    private let injectedEventBus: SuperEventBus?
    private var eventBus: SuperEventBus? { injectedEventBus ?? environmentEventBus }

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    private let catalog: BibleBookCatalog

    // Match ChatsScreen clearance above the minimized dock.
    private static let chatDockClearance: CGFloat = 96

    /// Nil eventBus uses the environment; tests may inject one without a SwiftUI host.
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
                    // Clear the shell's hamburger.
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

    private func assignment(for color: BibleBookmarkColor) -> BibleBookmarkRecord? {
        bookmarks.first { $0.color == color }
    }

    /// Unknown book IDs collapse to the empty-slot presentation.
    private func citation(for record: BibleBookmarkRecord) -> String? {
        guard let book = catalog.book(id: record.bookId) else { return nil }
        return "\(book.name) \(record.chapterNumber)"
    }

    /// Returns the publish task so tests can await delivery before draining the bus.
    @discardableResult
    func _openBookmark(bookId: String, chapterNumber: Int) -> Task<Void, Never>? {
        guard let eventBus else { return nil }
        let reference = BibleDeepLink(bookId: bookId, chapter: chapterNumber).recordReference
        return Task { await eventBus.publish(.openRecord(reference: reference)) }
    }

    static func rowLabel(color: BibleBookmarkColor, citation: String) -> String {
        "\(color.displayName) bookmark on \(citation). Open chapter"
    }
}
