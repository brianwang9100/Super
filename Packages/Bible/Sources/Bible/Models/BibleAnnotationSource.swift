import Foundation

/// Why an annotation was created.
///
/// `.user` covers both single-target taps (the bubble flow, the spark
/// button, the verse-action-modal row) and in-chat tool calls. `.userBulk`
/// is reserved for the future bulk runner (milestones M-B / M-C) so an
/// individual `regenerate` doesn't replace a bulk-generated row with a
/// `.user` row by accident, and so UI surfaces can distinguish the two
/// without a separate field.
public enum BibleAnnotationSource: String, Codable, Sendable, Equatable, CaseIterable {
    case user
    case userBulk
}
