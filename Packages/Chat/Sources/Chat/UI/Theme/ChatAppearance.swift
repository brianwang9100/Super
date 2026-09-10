import Core
import SwiftUI

public struct ChatAppearance: Sendable, Equatable {
    public let fontScale: Double

    public init(fontScale: Double) {
        self.fontScale = min(max(fontScale, 0.80), 1.20)
    }

    public static let `default` = ChatAppearance(fontScale: 1.0)

    public var markdownMetrics: MarkdownBodyMetrics {
        MarkdownBodyMetrics(fontScale: fontScale)
    }

    /// Absolute points; MarkdownUI does not apply Dynamic Type to FontSize.
    public var bodyFontSize: CGFloat { markdownMetrics.bodyFontSize }

    public var paragraphLineSpacingEm: CGFloat {
        markdownMetrics.paragraphLineSpacingEm
    }

    public var paragraphLineSpacingPoints: CGFloat {
        markdownMetrics.paragraphLineSpacingPoints
    }

    public var paragraphSpacing: CGFloat {
        markdownMetrics.paragraphSpacing
    }

    public var bubbleInnerVerticalPadding: CGFloat {
        interpolate(low: 6, mid: 10, high: 14)
    }

    public var bubbleRowVerticalPadding: CGFloat {
        interpolate(low: 2, mid: 4, high: 8)
    }

    /// Markdown contributes its own block margins, so assistant rows need less external padding.
    public var assistantRowVerticalPadding: CGFloat {
        interpolate(low: 1, mid: 2, high: 4)
    }

    /// Special-case 1.0 to return mid exactly; binary floating-point interpolation can differ by one ULP.
    private func interpolate(low: CGFloat, mid: CGFloat, high: CGFloat) -> CGFloat {
        let scale = CGFloat(fontScale)
        if scale == 1.0 { return mid }
        if scale < 1.0 {
            let t = (scale - 0.80) / 0.20
            return low + (mid - low) * t
        } else {
            let t = (scale - 1.00) / 0.20
            return mid + (high - mid) * t
        }
    }
}

struct ChatAppearanceKey: EnvironmentKey {
    static let defaultValue: ChatAppearance = .default
}

public extension EnvironmentValues {
    /// Restrict writes to chatAppearance(_:) so they also update markdownBodyMetrics.
    internal(set) var chatAppearance: ChatAppearance {
        get { self[ChatAppearanceKey.self] }
        set { self[ChatAppearanceKey.self] = newValue }
    }
}

public extension View {
    /// Inject appearance and shared Markdown metrics together.
    func chatAppearance(_ appearance: ChatAppearance) -> some View {
        environment(\.chatAppearance, appearance)
            .markdownBodyMetrics(appearance.markdownMetrics)
    }
}
