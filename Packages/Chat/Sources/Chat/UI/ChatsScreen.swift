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
    /// Reference time for relative-time bucketing in each row. A
    /// `@State` so the `.task` modifier below can refresh it every
    /// minute — a `let` captured at init time would freeze the
    /// subtitles ("12 min ago") for the whole session even as the
    /// `@Query` re-renders. Snapshot tests inject a fixed `now`; the
    /// refresh task can't fire inside a sub-millisecond test render.
    @State private var now: Date

    @Environment(\.superEventBus) private var environmentEventBus
    /// Test-only override of the event bus. Production callers leave
    /// this `nil` and the screen reads `@Environment(\.superEventBus)`
    /// from the shell; the unit-test suite injects a real
    /// `SuperEventBus` here to assert published payloads without
    /// constructing a SwiftUI host.
    private let injectedEventBus: SuperEventBus?
    private var eventBus: SuperEventBus? { injectedEventBus ?? environmentEventBus }
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    /// Search-field base size, declared via `@ScaledMetric` so the
    /// system-font input composes OS Dynamic Type on top of the app
    /// font-scale that `SuperTypography` folds in. The "Chats" title and
    /// the result-count line are brand serif / mono roles that carry
    /// Dynamic Type through their own `relativeTo`.
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
    ///   - eventBus: Unit-test-only test seam — overrides the
    ///     `@Environment(\.superEventBus)` lookup so a test can
    ///     observe published events without spinning up a SwiftUI
    ///     host. Production always leaves this `nil`.
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
        .task {
            // Keep the relative-time subtitles ("12 min ago") fresh
            // while the screen stays mounted. A row that read "5 min
            // ago" on open would otherwise still read "5 min ago"
            // hours later, since the @Query only fires on DB writes.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
                now = Date()
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        Text("Chats")
            .font(typography.display(36))
            .foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The bare `TextField`, with platform-conditional modifiers
    /// applied — `textInputAutocapitalization` only exists on UIKit
    /// platforms, so the macOS build (where `swift test` runs the
    /// non-UI suites) can't see it.
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
                            onTap: { _openConversation(id: record.id) }
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
        Button(action: _startNewChat) {
            Image(systemName: "plus")
                .font(typography.font(size: 18, weight: .semibold))
                .foregroundStyle(theme.ink)
                // 44×44 mirrors the shell's hamburger button so the two share a
                // baseline. The accent fill is gone — this is plain Liquid Glass
                // like the rest of the nav chrome; glass supplies its own edge
                // and elevation (no fill or shadow of its own).
                .frame(width: 44, height: 44)
                .superGlassButton(in: Circle())
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

    /// Publish an "open this conversation" request on the shared
    /// event bus. Internal (not private) so the unit-test suite can
    /// drive it directly; production fires it from the row's tap
    /// closure.
    func _openConversation(id: String) {
        guard let eventBus else { return }
        Task { await eventBus.publish(.openConversationRequested(id: id)) }
    }

    /// Publish a "start a new conversation" request on the shared
    /// event bus. Internal (not private) so the unit-test suite can
    /// drive it directly; production fires it from the `+` button.
    func _startNewChat() {
        guard let eventBus else { return }
        Task { await eventBus.publish(.newConversationRequested) }
    }
}
