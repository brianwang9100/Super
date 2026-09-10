import Core
import SwiftUI

public struct ChatEmptyState: View {
    public init() {}

    @Environment(\.superTheme) private var theme
    @Environment(\.chatEmptyStateGlyph) private var glyph

    public var body: some View {
        Group {
            switch glyph {
            // Canvas ignores inherited foregroundStyle; pass SparkIcon's tint explicitly.
            case .spark: SparkIcon(size: 36, color: theme.accent).opacity(0.8)
            case .star:  StarIcon(size: 40).foregroundStyle(theme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
    }
}

/// SuperOS defaults to spark; SuperBible injects star at its composition root.
public enum ChatEmptyStateGlyph: Sendable {
    case spark
    case star
}

struct ChatEmptyStateGlyphKey: EnvironmentKey {
    static let defaultValue: ChatEmptyStateGlyph = .spark
}

public extension EnvironmentValues {
    var chatEmptyStateGlyph: ChatEmptyStateGlyph {
        get { self[ChatEmptyStateGlyphKey.self] }
        set { self[ChatEmptyStateGlyphKey.self] = newValue }
    }
}

public extension View {
    func chatEmptyStateGlyph(_ glyph: ChatEmptyStateGlyph) -> some View {
        environment(\.chatEmptyStateGlyph, glyph)
    }
}
