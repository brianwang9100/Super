import Core
import CoreGraphics

/// Reading-surface spacing derived from the rendered verse-body size, so the
/// line and paragraph gaps track the font-scale slider and OS Dynamic Type the
/// same way the body text does. Pure (no SwiftUI) so it unit-tests like
/// `ChatAppearance`. The line gap is the shared `SuperTypography.readingLeadingEm`
/// (≈0.235 em), the same constant the assistant message body uses, so the two
/// EB Garamond reading surfaces have identical line rhythm; the `10/17`
/// paragraph margin is Bible-specific. Both multiply the rendered body size, so
/// the gaps scale proportionally with it. At the 19pt
/// `SuperTypography.readingBodySize` default they resolve to ≈4.47pt line gap /
/// ≈11.18pt paragraph margin at the 1.0× slider.
enum BibleReadingMetrics {
    /// Gap between wrapped prose lines and between poetry lines — the shared
    /// `SuperTypography.readingLeadingEm` resolved against the rendered body
    /// (≈3.2 / 4.5 / 5.4pt at the 0.8× / 1.0× / 1.2× slider over the 19pt body).
    /// - Parameters:
    ///   - bodySize: the rendered `@ScaledMetric` body point size (folds in OS Dynamic Type).
    ///   - fontScale: the app font-scale slider (`typography.fontScale`).
    static func lineSpacing(bodySize: CGFloat, fontScale: CGFloat) -> CGFloat {
        bodySize * fontScale * SuperTypography.readingLeadingEm
    }

    /// Gap between paragraphs / headings in the chapter reader. Same axes as
    /// ``lineSpacing(bodySize:fontScale:)``.
    static func paragraphSpacing(bodySize: CGFloat, fontScale: CGFloat) -> CGFloat {
        bodySize * fontScale * 10.0 / 17.0
    }
}
