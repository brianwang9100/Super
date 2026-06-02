import SwiftUI

/// UI-local projection of a `SourceCitation` for the transcript. Keeps
/// `MessageList` / `AssistantMessage` free of Core imports — they render pills
/// from this, never the Core type.
public struct SourceCitationPillModel: Identifiable, Sendable, Equatable {
    /// Matches the originating `SourceCitation.id` (derived from the URL +
    /// ordinal upstream), so a `ForEach` keyed on it can't collide.
    public let id: String
    /// Page title, or the host when the provider supplied no title.
    public let title: String
    /// Display domain, e.g. `"nasa.gov"` (leading `www.` stripped).
    public let host: String
    /// Full source URL; opened externally on tap.
    public let url: URL

    public init(id: String, title: String, host: String, url: URL) {
        self.id = id
        self.title = title
        self.host = host
        self.url = url
    }
}

/// Inline collapsible pill rendered under an assistant message that cited web
/// sources (native search today; standalone search later — both land their
/// citations in `MessageAttachments.sources`, so this one pill renders both).
///
/// Mirrors `MemoryUpdatedPill`'s ambient styling: a faint collapsed "N
/// sources" chip that expands to a per-source list (domain + truncated title).
/// Tapping a source opens it externally via `OpenURLAction`.
struct SourceCitationsPill: View {
    let sources: [SourceCitationPillModel]
    @State private var isExpanded: Bool
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.openURL) private var openURL

    /// Production initializer — pill starts collapsed; user taps to expand.
    init(sources: [SourceCitationPillModel]) {
        self.sources = sources
        self._isExpanded = State(initialValue: false)
    }

    /// Test-only seam that seeds `isExpanded` so snapshot tests can pin the
    /// expanded baseline without driving a tap. Underscore-prefixed per the
    /// codebase convention for non-stable test surface.
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
                // Arrow-up-right (external-link glyph): the rows open sources
                // in the browser. The "Web search" operation is announced by
                // the separate `WebSearchCallCell` above the answer.
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
        // Only follow web URLs. Citation URLs come from the provider's
        // response, and a BYOK setup can point at any Responses-compatible
        // proxy — a compromised one could inject a custom-scheme URL
        // (`app://`, `tel:`, `file://`) that `openURL` would hand to a
        // registered handler. Restrict to http(s), and reflect that in the
        // VoiceOver hint so the row doesn't promise an action it won't perform.
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
                    // Omit the title line when the source has no title beyond
                    // its host (projection collapses a host-equal title to "").
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
