import SwiftUI

public struct SourceCitationPillModel: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let host: String
    public let url: URL

    public init(id: String, title: String, host: String, url: URL) {
        self.id = id
        self.title = title
        self.host = host
        self.url = url
    }
}

struct SourceCitationsPill: View {
    let sources: [SourceCitationPillModel]
    @State private var isExpanded: Bool
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.openURL) private var openURL

    init(sources: [SourceCitationPillModel]) {
        self.sources = sources
        self._isExpanded = State(initialValue: false)
    }

    /// Snapshot seam for expanded state.
    init(sources: [SourceCitationPillModel], _isExpanded: Bool) {
        self.sources = sources
        self._isExpanded = State(initialValue: _isExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sources) { source in
                        sourceRow(source)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.backgroundSunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.borderFaint, lineWidth: 1)
        )
    }

    private var header: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.right")
                    .font(typography.font(.subheadline))
                    .foregroundStyle(theme.inkSoft)
                Text(countLabel)
                    .font(typography.font(.subheadline, weight: .medium))
                    .foregroundStyle(theme.ink)
                Spacer(minLength: 0)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(typography.font(.caption, weight: .semibold))
                    .foregroundStyle(theme.inkFaint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(countLabel)
        .accessibilityHint(isExpanded ? "Collapse sources" : "Show sources")
    }

    private func sourceRow(_ source: SourceCitationPillModel) -> some View {
        // Provider proxies supply these URLs; reject custom schemes that could invoke app handlers.
        let scheme = source.url.scheme?.lowercased()
        let canOpen = scheme == "https" || scheme == "http"
        return Button {
            if canOpen {
                openURL(source.url)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "globe")
                    .font(typography.font(.footnote))
                    .foregroundStyle(theme.inkFaint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.host)
                        .font(typography.font(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.inkSoft)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !source.title.isEmpty {
                        Text(source.title)
                            .font(typography.font(.footnote))
                            .foregroundStyle(theme.inkFaint)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(source.title.isEmpty ? source.host : "\(source.host), \(source.title)")
        .accessibilityHint(canOpen ? "Opens in your browser" : "")
    }

    private var countLabel: String {
        sources.count == 1 ? "1 source" : "\(sources.count) sources"
    }
}
