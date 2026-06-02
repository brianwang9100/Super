import SwiftUI

/// Inline cost-gate prompt for the native web-search proposal
/// (`request_web_search`). When the model asks to search and the "Ask before
/// each search" gate is ON, the proposal parks at `.awaitingConfirmation`
/// and this row offers **Search** / **Skip** beneath the assistant turn that
/// requested it. After the user decides, the same row collapses to a compact
/// one-line summary (searched / skipped) so the transcript keeps a record of
/// the decision without the leaky generic tool-call card.
///
/// Reads the proposed query + reason from the parked call's stored
/// parameters JSON via ``NativeWebSearch``. The `onSearch` / `onSkip`
/// closures route up through `MessageList` to the view model's
/// `confirmSearch(id:)` / `skipSearch(id:)`.
struct SearchConfirmationRow: View {
    let call: MessageList.ToolCallItem
    var onSearch: () -> Void = {}
    var onSkip: () -> Void = {}
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    /// Decoded once per render and threaded into the subviews — the proposal
    /// JSON is parsed a single time instead of once per `query`/`reason` read.
    private var fields: (query: String, reason: String) {
        NativeWebSearch.proposedFields(fromParametersJSON: call.parametersJSON)
    }

    var body: some View {
        switch call.status {
        case .awaitingConfirmation, .running:
            // `.running` is the brief window after `.toolCallStarted` but
            // before `awaitSearchDecision` flips the status to
            // `.awaitingConfirmation` and stores the continuation. We render
            // the same prompt so the buttons don't flicker in; a tap landing
            // in that sub-millisecond window routes to `confirmToolCall`/
            // `skipToolCall`, which no-op until the continuation exists — the
            // user simply taps again once it's parked. Harmless, not a dropped
            // action of consequence.
            prompt(fields: fields)
        case .success:
            summary(icon: "magnifyingglass", text: searchedSummaryText(query: fields.query), tint: theme.inkSoft)
        case .failed:
            summary(icon: "minus.circle", text: "Web search skipped.", tint: theme.inkFaint)
        }
    }

    // MARK: - Awaiting decision

    private func prompt(fields: (query: String, reason: String)) -> some View {
        let query = fields.query
        let reason = fields.reason
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(typography.font(.caption))
                    .foregroundStyle(theme.accent)
                Text("Search the web?")
                    .font(typography.font(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.ink)
            }
            if !query.isEmpty {
                Text("“\(query)”")
                    .font(typography.font(.subheadline))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !reason.isEmpty {
                Text(reason)
                    .font(typography.font(.caption))
                    .foregroundStyle(theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(action: onSkip) {
                    Text("Skip")
                        .font(typography.font(.subheadline, weight: .medium))
                        .foregroundStyle(theme.inkSoft)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(theme.borderFaint, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                Button(action: onSearch) {
                    Text("Search")
                        .font(typography.font(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.background)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 18)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(theme.accent)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.backgroundSunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.borderFaint, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(query.isEmpty ? "Search the web?" : "Search the web for \(query)?")
    }

    // MARK: - Resolved summary

    private func searchedSummaryText(query: String) -> String {
        query.isEmpty ? "Searched the web." : "Searched the web for “\(query)”."
    }

    private func summary(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(typography.font(.caption2))
                .foregroundStyle(tint)
            Text(text)
                .font(typography.font(.caption))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
