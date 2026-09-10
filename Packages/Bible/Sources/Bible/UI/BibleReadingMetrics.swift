import Core
import CoreGraphics

/// Reading gaps scale with text; line leading is shared with Chat, paragraph spacing is Bible-specific.
enum BibleReadingMetrics {
    /// bodySize already includes Dynamic Type; fontScale supplies the separate app slider.
    static func lineSpacing(bodySize: CGFloat, fontScale: CGFloat) -> CGFloat {
        bodySize * fontScale * SuperTypography.readingLeadingEm
    }

    static func paragraphSpacing(bodySize: CGFloat, fontScale: CGFloat) -> CGFloat {
        bodySize * fontScale * 10.0 / 17.0
    }
}
