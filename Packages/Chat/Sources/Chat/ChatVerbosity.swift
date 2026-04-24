import Foundation

/// Cross-applet verbosity preference for chat output.
///
/// `simple` collapses thinking and tool blocks, `thinking` expands thinking,
/// `verbose` expands everything. Lives in Core because settings, view models,
/// and the system-prompt builder all need to agree on the value.
public enum ChatVerbosity: String, Sendable, Equatable, Codable, CaseIterable {
    case simple
    case thinking
    case verbose

    /// Title-cased label suitable for settings rows and pills.
    public var displayName: String {
        switch self {
        case .simple: return "Simple"
        case .thinking: return "Thinking"
        case .verbose: return "Verbose"
        }
    }

    /// Numeric ordering used for `atLeast(_:)` comparisons.
    public var rank: Int {
        switch self {
        case .simple: return 0
        case .thinking: return 1
        case .verbose: return 2
        }
    }

    /// True if this verbosity is at least as detailed as `other`.
    public func atLeast(_ other: ChatVerbosity) -> Bool {
        rank >= other.rank
    }
}
