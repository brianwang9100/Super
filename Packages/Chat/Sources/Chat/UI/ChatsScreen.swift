import Core
import Foundation
import GRDBQuery
import SwiftUI

/// Root view of the Chats mini-applet — a searchable list of every
/// active conversation, newest-update-first. Mirrors the design in
/// `super/project/chats/app.jsx`.
///
/// Reactive: binds the conversation list via GRDBQuery `@Query` so
/// edits from other surfaces (the Chat overlay creating a chat, a
/// message send bumping `updatedAt`) repaint without a manual reload.
/// Search filtering runs client-side over the @Query result — the
/// only viable pattern until GRDBQuery's parameterized-request
/// threading lands; same approach `TodoScreen` uses for its filter.
public struct ChatsScreen: View {
    @Query(ActiveConversationsRequest()) private var conversations: [ConversationRecord]

    @State private var searchText: String
    /// Reference time for relative-time bucketing in each row.
    /// Snapshot tests inject a fixed `now` so baselines stay stable.
    private let now: Date
    private let calendar: Calendar = .current

    @Environment(\.superEventBus) private var eventBus
    @Environment(\.superTheme) private var theme
    @Environment(\.superFontScale) private var fontScale
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 30
    @ScaledMetric(relativeTo: .footnote) private var captionSize: CGFloat = 11
    @ScaledMetric(relativeTo: .subheadline) private var searchInputSize: CGFloat = 14

    /// Bottom inset that clears the shell's minimized "Chat with Super"
    /// dock. Mirrors `TodoScreen.chatDockClearance`.
    private static let chatDockClearance: CGFloat = 96

    /// - Parameters:
    ///   - initialSearchText: Snapshot-only test seam — seeds the
    ///     search field so a recorded baseline can render the
    ///     filter-active states without simulating typing.
    ///   - now: Snapshot-only test seam — fixes the reference time
    ///     for `RelativeTimeFormatter` bucketing.
    public init(initialSearchText: String = "", now: Date = Date()) {
        _searchText = State(initialValue: initialSearchText)
        self.now = now
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            theme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                    // 48pt clears the shell's 36pt hamburger (top: 4 +
                    // 36 + 8 gap), matching `TodoScreen`'s vertical
                    // baseline.
                    .padding(.top, 48)
                    .padding(.horizontal, 18)
                searchField
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                if trimmedQuery.isEmpty == false {
                    resultCountLine
                        .padding(.horizontal, 18)
                        .padding(.bottom, 4)
                }
                listSurface
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            addButton
        }
    }

    // MARK: - Subviews

    private var header: some View {
        Text("Chats")
            .font(.system(size: titleSize * fontScale, design: .serif))
            .foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The bare `TextField`, with platform-conditional modifiers
    /// applied — `textInputAutocapitalization` only exists on UIKit
    /// platforms, so the macOS build (where `swift test` runs the
    /// non-UI suites) can't see it.
    @ViewBuilder private var searchTextField: some View {
        let field = TextField("Search chats", text: $searchText)
            .font(.system(size: searchInputSize * fontScale))
            .foregroundStyle(theme.ink)
            .autocorrectionDisabled()
            .submitLabel(.search)
        #if canImport(UIKit)
        field.textInputAutocapitalization(.never)
        #else
        field
        #endif
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.inkFaint)
            searchTextField
            if searchText.isEmpty == false {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.inkMute)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.backgroundRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.borderFaint, lineWidth: 0.5)
        )
    }

    private var resultCountLine: some View {
        let count = filteredConversations.count
        let label = count == 1 ? "1 match" : "\(count) matches"
        return Text(label)
            .font(.system(size: captionSize * fontScale, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(theme.inkFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var listSurface: some View {
        // Zero-history takes precedence over no-search-match: a query
        // typed against an empty list is moot, so the more useful
        // "tap + to start" guidance wins.
        if conversations.isEmpty {
            emptyStateContainer(.noChats)
        } else if filteredConversations.isEmpty {
            emptyStateContainer(.noMatches(query: trimmedQuery))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredConversations, id: \.id) { record in
                        ChatsListRow(
                            title: displayTitle(for: record),
                            updatedAt: record.updatedAt,
                            now: now,
                            calendar: calendar,
                            onTap: { openConversation(id: record.id) }
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, Self.chatDockClearance)
            }
        }
    }

    /// Centers an empty-state view vertically in the space between the
    /// search bar and the chat dock — `Spacer` above and below so the
    /// content sits in the middle of the visible area, not tucked under
    /// the search field. Same composition for both modes so the two
    /// empty states share their vertical baseline.
    @ViewBuilder private func emptyStateContainer(_ mode: ChatsEmptyState.Mode) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ChatsEmptyState(mode: mode)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, Self.chatDockClearance)
    }

    private var addButton: some View {
        Button(action: startNewChat) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.accentInk)
                // 36×36 mirrors the shell's hamburger button; the 4pt
                // top offset puts it on the same baseline (safe-area
                // top + 4). Same modifier chain as `TodoScreen.addButton`.
                .frame(width: 36, height: 36)
                .background(theme.accent)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .padding(.trailing, 12)
        .accessibilityLabel("New chat")
    }

    // MARK: - Derived state

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredConversations: [ConversationRecord] {
        let q = trimmedQuery
        guard q.isEmpty == false else { return conversations }
        return conversations.filter { record in
            displayTitle(for: record).localizedCaseInsensitiveContains(q)
        }
    }

    private func displayTitle(for record: ConversationRecord) -> String {
        if let raw = record.title, raw.isEmpty == false { return raw }
        return "New chat"
    }

    // MARK: - Actions

    private func openConversation(id: String) {
        guard let eventBus else { return }
        Task { await eventBus.publish(.openConversationRequested(id: id)) }
    }

    private func startNewChat() {
        guard let eventBus else { return }
        Task { await eventBus.publish(.newConversationRequested) }
    }
}
