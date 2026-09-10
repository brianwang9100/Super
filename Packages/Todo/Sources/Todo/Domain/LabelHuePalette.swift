import Foundation

/// Picks the first unused hue, then rotates through the palette once all are taken.
public enum LabelHuePalette {
    public static let pool: [Double] = [
        220, 280, 25, 150, 200, 60, 320, 0, 100, 240, 340, 180, 45, 260,
    ]

    public static func nextHue(usedHues: Set<Double>, existingCount: Int) -> Double {
        if let fresh = pool.first(where: { !usedHues.contains($0) }) {
            return fresh
        }
        return pool[existingCount % pool.count]
    }
}
