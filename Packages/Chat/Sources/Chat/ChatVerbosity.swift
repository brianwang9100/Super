import Foundation

public enum ChatVerbosity: String, Sendable, Equatable, Codable, CaseIterable {
    case simple
    case thinking
    case verbose

    public var displayName: String {
        switch self {
        case .simple: return "Simple"
        case .thinking: return "Thinking"
        case .verbose: return "Verbose"
        }
    }

    public var rank: Int {
        switch self {
        case .simple: return 0
        case .thinking: return 1
        case .verbose: return 2
        }
    }

    public func atLeast(_ other: ChatVerbosity) -> Bool {
        rank >= other.rank
    }
}
