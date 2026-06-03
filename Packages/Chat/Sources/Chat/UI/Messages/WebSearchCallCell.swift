import SwiftUI

/// Tool-call-style cell announcing that the assistant performed a web search,
/// shown above the grounded answer it produced. Mirrors `ToolCallBlock`'s card
/// chrome, header typography, and "done" status so a web search reads like any
/// other tool invocation — and, like a tool call, expands to reveal the search
/// system, the query, and how many results came back. Rendered whenever an
/// assistant turn cited sources.
struct WebSearchCallCell: View {
    /// Human label for the search engine ("Debug (mock)", "Native search", …),
    /// or `nil` when unknown.
    let system: String?
    /// The query the assistant searched for, or `nil` when not captured.
    let query: String?
    /// Number of cited sources, shown as the RESULTS line.
    let sourceCount: Int
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @State private var isExpanded: Bool

    /// Production initializer — starts collapsed; user taps to expand.
    init(system: String?, query: String?, sourceCount: Int) {
        self.system = system
        self.query = query
        self.sourceCount = sourceCount
        self._isExpanded = State(initialValue: false)
    }

    /// Test-only seam that seeds `isExpanded` so snapshot tests can pin the
    /// expanded baseline without driving a tap.
    init(system: String?, query: String?, sourceCount: Int, _isExpanded: Bool) {
        self.system = system
        self.query = query
        self.sourceCount = sourceCount
        self._isExpanded = State(initialValue: _isExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(typography.font(.subheadline))
                        .foregroundStyle(theme.inkSoft)
                    Text("Web search")
                        .font(typography.font(.subheadline, weight: .medium))
                        .foregroundStyle(theme.ink)
                    statusBadge
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

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Mirror `ToolCallBlock`'s expanded body exactly: a plain
                    // monospace line for the identifier (SYSTEM ≈ FUNCTION), and
                    // bordered monospace code blocks for QUERY/RESULTS (≈
                    // INPUT/RESULT).
                    if let system, !system.isEmpty {
                        sectionLabel("SYSTEM")
                        Text(system)
                            .font(typography.mono(11, relativeTo: .caption2))
                            .foregroundStyle(theme.inkSoft)
                    }
                    if let query, !query.isEmpty {
                        sectionLabel("QUERY")
                        monospaceBlock(query)
                    }
                    sectionLabel("RESULTS")
                    monospaceBlock(resultsLabel)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Web search, done")
        .accessibilityHint(isExpanded ? "Collapse details" : "Show search details")
    }

    private var resultsLabel: String {
        sourceCount == 1 ? "1 source" : "\(sourceCount) sources"
    }

    /// Matches `ToolCallBlock`'s `.success` badge (checkmark + "done"): by the
    /// time a persisted turn renders, its citations have already arrived, so the
    /// search is complete. A live "searching…" state would need a streaming
    /// signal (deferred).
    private var statusBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(typography.font(.caption2, weight: .bold))
                .foregroundStyle(theme.accent)
            Text("done")
                .font(typography.font(.caption2))
                .foregroundStyle(theme.accent)
        }
    }

    /// Small-caps section label, identical to `ToolCallBlock`'s.
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(typography.font(.caption2, weight: .medium))
            .tracking(0.5)
            .foregroundStyle(theme.inkFaint)
    }

    /// Bordered, horizontally-scrolling monospace code block — identical to
    /// `ToolCallBlock`'s INPUT/RESULT panel, so the query and results read like
    /// a tool call's input/output.
    private func monospaceBlock(_ text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(typography.mono(11, relativeTo: .caption2))
                .foregroundStyle(theme.inkSoft)
                .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.background)
        )
    }
}
