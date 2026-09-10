import Foundation

/// Lifecycle of a single task. Persisted via `rawValue` (String) in the
/// `state` column on the `task` table. Case order matches the filter
/// sheet's pill order in the design.
public enum TaskState: String, Codable, Sendable, CaseIterable, Equatable {
    case open
    case done
    case cancelled

    public var displayName: String {
        switch self {
        case .open:      "Open"
        case .done:      "Completed"
        case .cancelled: "Cancelled"
        }
    }

    public var isTerminal: Bool {
        self != .open
    }
}
