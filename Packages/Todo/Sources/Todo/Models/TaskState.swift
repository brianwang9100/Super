import Foundation

/// Lifecycle of a single task. Persisted via `rawValue` (String) in the
/// `state` column on the `task` table. Case order matches the filter
/// sheet's pill order in the design.
public enum TaskState: String, Codable, Sendable, CaseIterable, Equatable {
    case open
    case done
    case cancelled

    /// Human-readable label rendered in the filter sheet and edit modal.
    public var displayName: String {
        switch self {
        case .open:      "Open"
        case .done:      "Completed"
        case .cancelled: "Cancelled"
        }
    }

    /// Whether the row should render with muted styling (line-through for
    /// cancelled, dimmed accent stripe for done).
    public var isTerminal: Bool {
        self != .open
    }
}
