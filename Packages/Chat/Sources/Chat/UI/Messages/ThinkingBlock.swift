import Core
import Foundation
import SwiftUI

struct ThinkingBlock: View {
    let text: String
    let durationSource: DurationSource
    let verbosity: ChatVerbosity
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @State private var isExpanded: Bool
    private let expansionOverride: Binding<Bool>?
    private var expansion: Binding<Bool> { expansionOverride ?? $isExpanded }

    enum DurationSource: Equatable {
        case live(startedAt: Date)
        case finished(durationMs: Int?)
    }

    init(text: String, durationSource: DurationSource, verbosity: ChatVerbosity, expansion: Binding<Bool>? = nil) {
        self.expansionOverride = expansion
        self.text = text
        self.durationSource = durationSource
        self.verbosity = verbosity
        self._isExpanded = State(initialValue: Self.shouldExpand(for: verbosity))
    }

    static func shouldExpand(for verbosity: ChatVerbosity) -> Bool {
        verbosity.atLeast(.thinking)
    }

    /// Apply partial-input repair only while streaming, when Markdown closers may still be in flight.
    private var isLive: Bool {
        if case .live = durationSource { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expansion.wrappedValue, !text.isEmpty {
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
        // A verbosity change resets expansion; later manual toggles win until the next change.
        .onChange(of: verbosity) { _, newValue in
            expansion.wrappedValue = Self.shouldExpand(for: newValue)
        }
    }

    @ViewBuilder
    private var header: some View {
        switch durationSource {
        case .live(let startedAt):
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
            expansion.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(typography.font(.caption))
                    .foregroundStyle(theme.inkSoft)
                Text(label)
                    .font(typography.font(.footnote, weight: .medium))
                    .foregroundStyle(theme.inkSoft)
                Spacer(minLength: 0)
                Image(systemName: expansion.wrappedValue ? "chevron.down" : "chevron.right")
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

    static func label(forSeconds seconds: Int) -> String {
        "Thought for \(max(0, seconds))s"
    }

    /// Missing durations in legacy rows use the bare Thinking label.
    static func label(forDurationMs durationMs: Int?) -> String {
        guard let ms = durationMs else { return "Thinking" }
        let seconds = Int((Double(ms) / 1000.0).rounded())
        return label(forSeconds: seconds)
    }
}
