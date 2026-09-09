import Foundation

/// `.user` covers single-target and in-chat generation; `.userBulk` marks bulk-run output.
public enum BibleAnnotationSource: String, Codable, Sendable, Equatable, CaseIterable {
    case user
    case userBulk
}
