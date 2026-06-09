import Core
import SwiftUI

/// Centered brand glyph shown when a conversation has no messages.
///
/// The glyph is chosen per-target through `\.chatEmptyStateGlyph`: SuperOS
/// keeps its `SparkIcon`, SuperBible overrides to the `StarIcon` (Star of
/// Bethlehem). Accent-tinted, solid, no text.
public struct ChatEmptyState: View {
    public init() {}

    @Environment(\.superTheme) private var theme
    @Environment(\.chatEmptyStateGlyph) private var glyph

    public var body: some View {
        Group {
            switch glyph {
            // SuperOS's spark, accent-tinted at 0.8 — same treatment as the
            // streaming `WaitingSpark` spinner. `SparkIcon`'s `Canvas` strokes
            // with its `color` argument (an ancestor `.foregroundStyle` never
            // reaches it), so the tint is passed explicitly. Without the text
            // that used to anchor it, a bare `.primary` spark went nearly
            // invisible on the dark theme background.
            case .spark: SparkIcon(size: 36, color: theme.accent).opacity(0.8)
            // SuperBible's solid accent Star of Bethlehem. `StarIcon` fills
            // `.foreground`, which `.foregroundStyle(theme.accent)` resolves.
            case .star:  StarIcon(size: 40).foregroundStyle(theme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
    }
}

/// Which brand mark the chat empty state renders. Defaults to `.spark`
/// (SuperOS); SuperBible injects `.star` at its composition root.
public enum ChatEmptyStateGlyph: Sendable {
    case spark
    case star
}

/// SwiftUI environment plumbing — only the `\.chatEmptyStateGlyph` accessor
/// and `View.chatEmptyStateGlyph(_:)` modifier are public surface. The key
/// stays internal so it isn't re-exported as API.
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
    /// Inject the chat empty-state brand glyph for this subtree. SuperBible
    /// sets `.star` at its `AppShell`; SuperOS leaves the `.spark` default.
    func chatEmptyStateGlyph(_ glyph: ChatEmptyStateGlyph) -> some View {
        environment(\.chatEmptyStateGlyph, glyph)
    }
}
