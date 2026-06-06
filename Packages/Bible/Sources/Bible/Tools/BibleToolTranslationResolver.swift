import Foundation

/// Resolves the `translation` argument shared by the Bible lookup tools
/// (`bible.read`, `bible.search`): an explicit, strictly-validated code, or —
/// when omitted/blank — the user's currently selected translation (falling back
/// to the default when no position is stored or the store is unavailable).
///
/// A caseless namespace so both tools resolve translations identically; an
/// unknown explicit code is a correctable error, never a silent fallback.
enum BibleToolTranslationResolver {
    /// - Parameters:
    ///   - explicitCode: the raw `translation` argument as passed by the model
    ///     (may be `nil`, blank, or any case); `nil`/blank selects the
    ///     current-translation fallback.
    ///   - positionRepository: the reading-position store consulted for the
    ///     current translation; `nil` (store unavailable) falls back to the
    ///     default.
    /// - Throws: `BibleToolValidationError` when `explicitCode` names an unknown
    ///   translation.
    static func resolve(
        explicitCode: String?,
        positionRepository: (any BibleReadingPositionRepository)?
    ) async throws -> BibleTranslation {
        if let raw = explicitCode,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            // Strict: `init(rawValue:)`, never `.named(_:)`, so an unknown code is
            // an error the model can correct rather than a silent fallback.
            guard let translation = BibleTranslation(rawValue: code) else {
                let valid = BibleTranslation.allCases.map(\.rawValue).joined(separator: ", ")
                throw BibleToolValidationError("Unknown translation '\(raw)'. Available: \(valid).")
            }
            return translation
        }
        var storedCode: String?
        if let positionRepository {
            storedCode = (try? await positionRepository.load())?.translationId
        }
        return storedCode.flatMap(BibleTranslation.init(rawValue:)) ?? .defaultTranslation
    }
}

/// A soft input failure raised by the Bible tools' shared argument resolution,
/// caught in each tool's `execute` and returned as an `isError` `ToolResult` so
/// the model can correct its arguments instead of tearing down the turn.
struct BibleToolValidationError: Error, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}
