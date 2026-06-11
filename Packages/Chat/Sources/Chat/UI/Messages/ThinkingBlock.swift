import Foundation
import SwiftUI

/// Collapsible reasoning trace block. Header shows "Thought for Xs" with
/// a 1Hz live tick while streaming and a static label once finished;
/// expanded body renders the trace as soft-ink markdown. `.simple`
/// verbosity keeps it collapsed; `.thinking` and `.verbose` open it.
struct ThinkingBlock: View {
    let text: String
    let durationSource: DurationSource
    let verbosity: ChatVerbosity
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @State private var isExpanded: Bool

    /// Two distinct duration sources: `.live` ticks against the wall clock
    /// while the assistant is still thinking, `.finished` shows a static
    /// label backed by the persisted millisecond count.
    enum DurationSource: Equatable {
        case live(startedAt: Date)
        case finished(durationMs: Int?)
    }

    /// `.simple` collapses the body so the user just sees a "Thought for
    /// Xs" pill they can tap to inspect; `.thinking` and `.verbose` open
    /// expanded so the trace is visible without an extra tap.
    init(text: String, durationSource: DurationSource, verbosity: ChatVerbosity) {
        self.text = text
        self.durationSource = durationSource
        self.verbosity = verbosity
        self._isExpanded = State(initialValue: Self.shouldExpand(for: verbosity))
    }

    /// `.simple` keeps the body collapsed; `.thinking` and `.verbose` open
    /// it. Centralized so init and the verbosity-change observer agree.
    static func shouldExpand(for verbosity: ChatVerbosity) -> Bool {
        verbosity.atLeast(.thinking)
    }

    /// Live thinking traces stream the same way assistant text does, so
    /// they need the same partial-input autoclose pass — otherwise an
    /// unclosed fence/link in the reasoning buffer would visually break
    /// while the closer is still in flight. Persisted thinking
    /// (`.finished`) renders verbatim because the row is committed once
    /// the turn is over.
    private var isLive: Bool {
        if case .live = durationSource { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded, !text.isEmpty {
                MarkdownText(text, bodyStyleOverride: .thinking, treatAsPartial: isLive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.backgroundSunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.borderFaint, lineWidth: 1)
        )
        // Verbosity changes broadcast a new default expansion state to every
        // block. Individual taps after that still win until the next switch.
        .onChange(of: verbosity) { _, newValue in
            isExpanded = Self.shouldExpand(for: newValue)
        }
    }

    @ViewBuilder
    private var header: some View {
        switch durationSource {
        case .live(let startedAt):
            // 1Hz timeline so the second counter ticks while the model is
            // still thinking. The view stays cheap — only the label inside
            // the timeline re-renders.
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                headerButton(label: Self.label(forSeconds: Int(elapsed.rounded(.down))))
            }
        case .finished(let durationMs):
            headerButton(label: Self.label(forDurationMs: durationMs))
        }
    }

    @ViewBuilder
    private func headerButton(label: String) -> some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(typography.font(.caption))
                    .foregroundStyle(theme.inkSoft)
                Text(label)
                    .font(typography.font(.footnote, weight: .medium))
                    .foregroundStyle(theme.inkSoft)
                Spacer(minLength: 0)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(typography.font(.caption2, weight: .semibold))
                    .foregroundStyle(theme.inkFaint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Thought for Xs" using the live elapsed second count. The first
    /// second is rendered as "0s" so the label appears the instant a
    /// thinking delta arrives — same convention every major chat UI uses.
    static func label(forSeconds seconds: Int) -> String {
        "Thought for \(max(0, seconds))s"
    }

    /// Persisted-row variant: rounds the millisecond count to seconds and
    /// falls back to the bare "Thinking" label when no duration was
    /// recorded (legacy rows from before the column existed).
    static func label(forDurationMs durationMs: Int?) -> String {
        guard let ms = durationMs else { return "Thinking" }
        let seconds = Int((Double(ms) / 1000.0).rounded())
        return label(forSeconds: seconds)
    }
}
