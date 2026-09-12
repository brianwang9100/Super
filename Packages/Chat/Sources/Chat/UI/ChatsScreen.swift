import Core
import Foundation
import GRDBQuery
import SwiftUI

public struct ChatsScreen: View {
    @Query(ActiveConversationsRequest()) private var conversations: [ConversationRecord]

    @State private var searchText: String
    @State private var now: Date

    @Environment(\.superEventBus) private var environmentEventBus
    private let injectedEventBus: SuperEventBus?
    private var eventBus: SuperEventBus? { injectedEventBus ?? environmentEventBus }
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    /// System faces need ScaledMetric; brand roles carry Dynamic Type through relativeTo.
    @ScaledMetric(relativeTo: .subheadline) private var searchInputSize: CGFloat = 14

    private static let chatDockClearance: CGFloat = 96

    /// Initial search and time pin snapshots; eventBus lets tests observe actions without hosting SwiftUI.
    public init(
        initialSearchText: String = "",
        now: Date = Date(),
        eventBus: SuperEventBus? = nil
    ) {
        _searchText = State(initialValue: initialSearchText)
        _now = State(initialValue: now)
        self.injectedEventBus = eventBus
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            theme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                    // Clear the shell hamburger: 4pt top + 36pt button + 8pt gap.
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
            .frame(maxWidth: SuperContentLayout.maximumColumnWidth, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .topTrailing) { addButton }
            .frame(maxWidth: .infinity)
        }
        .task {
            // @Query refreshes on writes, so relative timestamps need their own timer.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
                now = Date()
            }
        }
    }

    private var header: some View {
        Text("Chats")
            .font(typography.display(36))
            .foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var searchTextField: some View {
        let field = TextField("Search chats", text: $searchText)
            .font(typography.font(size: searchInputSize))
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
                .font(typography.font(size: 14, weight: .medium))
                .foregroundStyle(theme.inkFaint)
            searchTextField
            if searchText.isEmpty == false {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(typography.font(size: 14))
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
            .font(typography.mono(11, relativeTo: .footnote))
            .tracking(0.5)
            .foregroundStyle(theme.inkFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var listSurface: some View {
        // Prefer first-run guidance over a failed search when history is empty.
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
                            onTap: { _openConversation(id: record.id) }
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, Self.chatDockClearance)
            }
        }
    }

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
        Button(action: { _startNewChat() }) {
            Image(systemName: "plus")
                .font(typography.font(size: 18, weight: .semibold))
                .foregroundStyle(theme.accentInk)
                .frame(width: 44, height: 44)
                .superGlassCTAButton(in: Circle())
        }
        .buttonStyle(GlassHapticButtonStyle(.primary))
        .padding(.top, 4)
        .padding(.trailing, 12)
        .accessibilityLabel("New chat")
    }

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

    /// Return the publish task so tests can await delivery without timeout races.
    @discardableResult
    func _openConversation(id: String) -> Task<Void, Never>? {
        guard let eventBus else { return nil }
        return Task { await eventBus.publish(.openConversationRequested(id: id)) }
    }

    /// Returns the publish task, as with _openConversation.
    @discardableResult
    func _startNewChat() -> Task<Void, Never>? {
        guard let eventBus else { return nil }
        return Task { await eventBus.publish(.newConversationRequested) }
    }
}
