import CoreGraphics

/// Reading-surface spacing derived from the rendered verse-body size, so the
/// line and paragraph gaps track the font-scale slider and OS Dynamic Type the
/// same way the body text does. Pure (no SwiftUI) so it unit-tests like
/// `ChatAppearance`. The em ratios (`4/17` line gap, `10/17` paragraph margin)
/// are expressed against the 17pt default body so the gaps scale proportionally.
/// Division is written last so the default resolves to exact points (no sub-ULP
/// drift in snapshot baselines): 4pt line gap / 10pt paragraph margin at 1.0×.
enum BibleReadingMetrics {
    /// Gap between wrapped prose lines and between poetry lines. `4/17` gives
    /// 3.2 / 4 / 4.8pt at the 0.8× / 1.0× / 1.2× slider anchors over the
    /// default body.
    /// - Parameters:
    ///   - bodySize: the rendered `@ScaledMetric` body point size (folds in OS Dynamic Type).
    ///   - fontScale: the app font-scale slider (`typography.fontScale`).
    static func lineSpacing(bodySize: CGFloat, fontScale: CGFloat) -> CGFloat {
        bodySize * fontScale * 4.0 / 17.0
    }

    /// Gap between paragraphs / headings in the chapter reader. Same axes as
    /// ``lineSpacing(bodySize:fontScale:)``.
    static func paragraphSpacing(bodySize: CGFloat, fontScale: CGFloat) -> CGFloat {
        bodySize * fontScale * 10.0 / 17.0
    }
}
