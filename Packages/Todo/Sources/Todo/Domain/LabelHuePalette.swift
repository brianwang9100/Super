import Foundation

/// Curated hue rotation used when the user creates a brand-new label.
/// Mirrors the design prototype's `LABEL_HUE_POOL`: picks the first hue
/// not currently in use, falling back to round-robin once all are taken.
public enum LabelHuePalette {
    public static let pool: [Double] = [
        220, 280, 25, 150, 200, 60, 320, 0, 100, 240, 340, 180, 45, 260,
    ]

    /// - Parameters:
    ///   - usedHues: hues already assigned to existing labels.
    ///   - existingCount: label count, used to round-robin once every
    ///     pool hue is taken.
    public static func nextHue(usedHues: Set<Double>, existingCount: Int) -> Double {
        if let fresh = pool.first(where: { !usedHues.contains($0) }) {
            return fresh
        }
        return pool[existingCount % pool.count]
    }
}
