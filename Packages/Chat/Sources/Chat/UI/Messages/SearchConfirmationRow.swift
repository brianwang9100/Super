import SwiftUI

struct SearchConfirmationRow: View {
    let call: MessageList.ToolCallItem
    var onSearch: () -> Void = {}
    var onSkip: () -> Void = {}
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    private var fields: (query: String, reason: String) {
        NativeWebSearch.proposedFields(fromParametersJSON: call.parametersJSON)
    }

    var body: some View {
        switch call.status {
        case .awaitingConfirmation, .running:
            // Keep the prompt stable during the brief running-to-awaiting transition.
            // A tap before the continuation is installed is ignored.
            prompt(fields: fields)
        case .success:
            // The answer's WebSearchCallCell records approved searches, including zero-result searches.
            EmptyView()
        case .failed:
            // A skipped search has no answer metadata; preserve its record here.
            summary(icon: "minus.circle", text: "Web search skipped.", tint: theme.inkFaint)
        }
    }

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

    private func summary(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(typography.font(.callout))
                .foregroundStyle(tint)
            Text(text)
                .font(typography.font(.body))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
