import SwiftUI

/// Composer footer pill that toggles assistant verbosity (Simple / Thinking
/// / Verbose). Reads `ChatVerbosity` (Chat-owned) and propagates the new
/// value via `onSelect`.
///
/// Mirrors `VerbosityPill` in `.design-tmp/chat/project/src/chat-view.jsx`.
public struct VerbosityPill: View {
    public let verbosity: ChatVerbosity
    public let onSelect: (ChatVerbosity) -> Void

    public init(verbosity: ChatVerbosity, onSelect: @escaping (ChatVerbosity) -> Void) {
        self.verbosity = verbosity
        self.onSelect = onSelect
    }

    @Environment(\.superTheme) private var theme

    public var body: some View {
        Menu {
            ForEach(ChatVerbosity.allCases, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.displayName)
                            .font(.system(.footnote).weight(.medium))
                        Text(Self.subtitle(for: option))
                            .font(.system(.caption2))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            FooterPillLabel(text: verbosity.displayName, theme: theme)
        }
        .menuStyle(.borderlessButton)
        .menuOrder(.fixed)
    }

    /// Subtitle copy for each verbosity row, sourced from
    /// `.design-tmp/chat/project/src/chat-view.jsx`'s `VerbosityPill`.
    static func subtitle(for verbosity: ChatVerbosity) -> String {
        switch verbosity {
        case .simple:   return "Just the answer"
        case .thinking: return "Show thinking"
        case .verbose:  return "Show everything"
        }
    }
}
