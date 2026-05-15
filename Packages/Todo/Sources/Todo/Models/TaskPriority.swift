import Foundation

/// Task urgency. Persisted as `Int` (1 = urgent, 2 = high, 3 = normal) so
/// the SQLite column is a plain `INTEGER` and sort queries can
/// `ORDER BY priority ASC` without a `CASE` expression.
public enum TaskPriority: Int, Codable, Sendable, CaseIterable, Equatable, Comparable {
    case urgent = 1
    case high   = 2
    case normal = 3

    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Long-form label (filter sheet, edit modal).
    public var displayName: String {
        switch self {
        case .urgent: "Urgent"
        case .high:   "High"
        case .normal: "Normal"
        }
    }

    /// Hue (0–360°) used to compute the task row's priority stripe color.
    /// Matches the `PRI` hues in the design prototype.
    public var hue: Double {
        switch self {
        case .urgent: 25
        case .high:   60
        case .normal: 150
        }
    }
}
