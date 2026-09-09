import SwiftUI

public struct MarkdownBodyMetrics: Sendable, Equatable {
    /// Host-clamped multiplier, expected in 0.80...1.20; this projection does not clamp again.
    public let fontScale: CGFloat

    public init(fontScale: CGFloat) {
        self.fontScale = fontScale
    }

    public static let `default` = MarkdownBodyMetrics(fontScale: 1.0)

    /// Points. MarkdownUI does not read Dynamic Type; relative heading/code sizes scale from this base.
    public var bodyFontSize: CGFloat { SuperTypography.readingBodySize * fontScale }

    /// Em ratio shared with Bible reading text.
    public var paragraphLineSpacingEm: CGFloat {
        SuperTypography.readingLeadingEm
    }

    public var paragraphLineSpacingPoints: CGFloat {
        paragraphLineSpacingEm * bodyFontSize
    }

    /// Paragraph margin in points.
    public var paragraphSpacing: CGFloat {
        (16.0 / 17.0) * bodyFontSize
    }
}

struct MarkdownBodyMetricsKey: EnvironmentKey {
    static let defaultValue: MarkdownBodyMetrics = .default
}

public extension EnvironmentValues {
    var markdownBodyMetrics: MarkdownBodyMetrics {
        get { self[MarkdownBodyMetricsKey.self] }
        set { self[MarkdownBodyMetricsKey.self] = newValue }
    }
}

public extension View {
    func markdownBodyMetrics(_ metrics: MarkdownBodyMetrics) -> some View {
        environment(\.markdownBodyMetrics, metrics)
    }
}
